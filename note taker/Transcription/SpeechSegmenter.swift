//
//  SpeechSegmenter.swift
//  note taker
//

import Foundation

/// One stretch of speech cut out of a track: 16 kHz mono samples and where they start.
nonisolated struct Utterance: Sendable {
    /// Seconds from the start of the track.
    var start: TimeInterval
    var samples: [Float]

    var duration: TimeInterval { Double(samples.count) / SpeechSegmenter.sampleRate }
    var end: TimeInterval { start + duration }
}

/// What one window changed.
nonisolated struct SegmenterOutput {
    /// Audio this window added to the utterance in progress, and where it starts in the
    /// track. Streaming models transcribe it right away.
    var speech: (start: TimeInterval, samples: [Float])?
    /// An utterance this window completed.
    var finished: Utterance?
    /// The utterance in progress was dropped as too short to be speech.
    var discarded = false
}

/// Turns a stream of VAD speech probabilities into utterances, dropping the silence
/// between them. Fed one 32 ms window at a time, so it works the same live and on a file.
nonisolated struct SpeechSegmenter {
    static let sampleRate: Double = 16_000

    nonisolated struct Settings {
        /// A window at or above this probability is speech.
        var threshold: Float = 0.5
        /// Speech only counts as stopped below this, so it doesn't flicker around `threshold`.
        var silenceThreshold: Float = 0.35
        /// A pause this long ends an utterance.
        var minSilence: TimeInterval = 0.5
        /// Once an utterance is longer than `longUtterance`, a shorter pause ends it,
        /// so lines keep coming during long monologues.
        var longUtterance: TimeInterval = 12
        var minSilenceWhenLong: TimeInterval = 0.2
        /// Utterances are cut at this length even without a pause. Whisper reads 30 s at most.
        var maxUtterance: TimeInterval = 20
        /// Utterances with less speech than this are dropped as clicks and coughs.
        var minSpeech: TimeInterval = 0.25
        /// Audio kept before and after the speech, so the first and last sounds aren't clipped.
        var padding: TimeInterval = 0.2
    }

    let settings: Settings

    /// Samples fed so far.
    private var position = 0
    /// The last `padding` of audio before speech started.
    private var preRoll: [Float] = []
    private var current: Utterance?
    /// Where each window fed into `current` starts in it, and its speech probability.
    /// Used to pick a cut point when an utterance runs too long.
    private var windows: [(offset: Int, probability: Float)] = []
    private var speechSamples = 0
    private var trailingSilence = 0

    init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Feeds one window and its speech probability.
    mutating func process(_ window: [Float], probability: Float) -> SegmenterOutput {
        defer { position += window.count }

        guard var utterance = current else {
            if probability >= settings.threshold {
                let started = Utterance(start: Double(position - preRoll.count) / Self.sampleRate, samples: preRoll + window)
                current = started
                windows = [(offset: preRoll.count, probability: probability)]
                speechSamples = window.count
                trailingSilence = 0
                preRoll = []
            } else {
                preRoll.append(contentsOf: window)
                let keep = samples(settings.padding)
                if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
                return SegmenterOutput()
            }
            return SegmenterOutput(speech: (started.start, started.samples))
        }

        windows.append((offset: utterance.samples.count, probability: probability))
        utterance.samples.append(contentsOf: window)
        if probability >= settings.threshold {
            speechSamples += window.count
            trailingSilence = 0
        } else if probability < settings.silenceThreshold || trailingSilence > 0 {
            trailingSilence += window.count
        }
        current = utterance
        var output = SegmenterOutput(speech: (Double(position) / Self.sampleRate, window))

        let neededSilence = utterance.duration > settings.longUtterance
            ? settings.minSilenceWhenLong
            : settings.minSilence
        if trailingSilence >= samples(neededSilence) {
            output.finished = endUtterance()
            output.discarded = output.finished == nil
        } else if utterance.duration >= settings.maxUtterance {
            output.finished = cutLongUtterance(windowSize: window.count)
        }
        return output
    }

    /// Ends the utterance in progress, for when the audio stops.
    mutating func finish() -> SegmenterOutput {
        guard current != nil else { return SegmenterOutput() }
        let finished = endUtterance()
        return SegmenterOutput(finished: finished, discarded: finished == nil)
    }

    /// Ends the current utterance at the pause, keeping `padding` of it. Returns nil
    /// if it had too little speech.
    private mutating func endUtterance() -> Utterance? {
        guard var utterance = current else { return nil }
        let silenceToDrop = min(max(0, trailingSilence - samples(settings.padding)), utterance.samples.count)
        // The dropped silence leads into whatever is said next.
        preRoll = Array(utterance.samples.suffix(silenceToDrop).suffix(samples(settings.padding)))
        utterance.samples.removeLast(silenceToDrop)

        let enoughSpeech = speechSamples >= samples(settings.minSpeech)
        current = nil
        windows = []
        speechSamples = 0
        trailingSilence = 0
        return enoughSpeech ? utterance : nil
    }

    /// Splits an utterance that hit `maxUtterance` at its quietest point in the last few
    /// seconds, so a word is less likely to be cut in half. The rest carries on.
    private mutating func cutLongUtterance(windowSize: Int) -> Utterance? {
        guard let utterance = current else { return nil }
        let searchFrom = utterance.samples.count - samples(5)
        let quietest = windows.indices
            .filter { windows[$0].offset > 0 && windows[$0].offset >= searchFrom }
            .min { windows[$0].probability < windows[$1].probability }
        guard let quietest else { return endUtterance() }
        let cut = windows[quietest].offset

        let head = Utterance(start: utterance.start, samples: Array(utterance.samples[..<cut]))
        current = Utterance(
            start: utterance.start + Double(cut) / Self.sampleRate,
            samples: Array(utterance.samples[cut...])
        )
        windows = windows[quietest...].map { (offset: $0.offset - cut, probability: $0.probability) }
        speechSamples = windows.filter { $0.probability >= settings.threshold }.count * windowSize
        trailingSilence = min(trailingSilence, current?.samples.count ?? 0)
        return head
    }

    private func samples(_ seconds: TimeInterval) -> Int {
        Int(seconds * Self.sampleRate)
    }
}
