//
//  LiveTrackProcessor.swift
//  note taker
//

import AVFoundation

/// Takes one track's audio while it's being recorded, resamples it to 16 kHz mono, runs
/// Silero VAD on it and hands over each utterance as soon as the speaker pauses.
/// Silence never reaches the speech model.
nonisolated final class LiveTrackProcessor: @unchecked Sendable {
    nonisolated enum Event: Sendable {
        /// Speech as it's heard, before the utterance ends. Only sent with `forwardsSpeech`.
        case speech(start: TimeInterval, samples: [Float])
        /// A finished utterance.
        case utterance(Utterance)
        /// The speech sent since the last utterance turned out to be a click or a cough.
        case discarded
    }

    private let queue: DispatchQueue
    private let vad: SileroVAD
    private let forwardsSpeech: Bool
    private let onEvent: @Sendable (Event) -> Void
    private var segmenter = SpeechSegmenter()
    private var converter: AVAudioConverter?
    /// Resampled audio that doesn't fill a VAD window yet.
    private var pending: [Float] = []
    private var isFinished = false

    /// `onEvent` is called on a background queue, in order. `forwardsSpeech` is for models
    /// that stream natively and transcribe speech while it's still being said.
    init(label: String, forwardsSpeech: Bool, onEvent: @escaping @Sendable (Event) -> Void) throws {
        vad = try SileroVAD()
        queue = DispatchQueue(label: "LiveTrackProcessor.\(label)", qos: .userInitiated)
        self.forwardsSpeech = forwardsSpeech
        self.onEvent = onEvent
    }

    /// Called from the audio callback. The buffer is copied, so it can be reused right away.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.copied() else { return }
        queue.async { [self] in
            guard !isFinished, let samples = resample(copy) else { return }
            pending.append(contentsOf: samples)
            processPendingWindows()
        }
    }

    /// Waits for queued audio, then hands over the utterance still in progress, if any.
    func finish() {
        queue.sync {
            guard !isFinished else { return }
            isFinished = true
            send(segmenter.finish())
        }
    }

    private func processPendingWindows() {
        let size = SileroVAD.windowSize
        var start = 0
        // Speech from consecutive windows goes out as one piece per buffer.
        var speech: (start: TimeInterval, samples: [Float])?
        while start + size <= pending.count {
            let window = Array(pending[start..<(start + size)])
            start += size
            // A failed window counts as silence rather than stopping the transcript.
            let probability = (try? vad.speechProbability(window)) ?? 0
            let output = segmenter.process(window, probability: probability)
            if forwardsSpeech, let piece = output.speech {
                if speech == nil {
                    speech = piece
                } else {
                    speech?.samples.append(contentsOf: piece.samples)
                }
            }
            if output.finished != nil || output.discarded {
                flush(&speech)
                send(output)
            }
        }
        flush(&speech)
        pending.removeFirst(start)
    }

    private func flush(_ speech: inout (start: TimeInterval, samples: [Float])?) {
        if let piece = speech {
            onEvent(.speech(start: piece.start, samples: piece.samples))
        }
        speech = nil
    }

    private func send(_ output: SegmenterOutput) {
        if let utterance = output.finished {
            onEvent(.utterance(utterance))
        } else if output.discarded, forwardsSpeech {
            onEvent(.discarded)
        }
    }

    private func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        if converter?.inputFormat != buffer.format {
            // The first buffer, or the device changed format mid-recording.
            converter = AVAudioConverter(from: buffer.format, to: Self.speechFormat)
            converter?.downmix = true
        }
        guard let converter else { return nil }

        let ratio = Self.speechFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.speechFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// What the VAD and speech models take: 16 kHz mono Float32.
    static let speechFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: SpeechSegmenter.sampleRate,
        channels: 1,
        interleaved: false
    )!
}
