//
//  LiveTrackProcessor.swift
//  note taker
//

import AVFoundation

/// Takes one track's audio while it's being recorded, resamples it to 16 kHz mono, runs
/// Silero VAD on it and hands over each utterance as soon as the speaker pauses.
/// Silence never reaches the speech model.
nonisolated final class LiveTrackProcessor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let vad: SileroVAD
    private let onUtterance: @Sendable (Utterance) -> Void
    private var segmenter = SpeechSegmenter()
    private var converter: AVAudioConverter?
    /// Resampled audio that doesn't fill a VAD window yet.
    private var pending: [Float] = []
    private var isFinished = false

    /// `onUtterance` is called on a background queue, in order.
    init(label: String, onUtterance: @escaping @Sendable (Utterance) -> Void) throws {
        vad = try SileroVAD()
        queue = DispatchQueue(label: "LiveTrackProcessor.\(label)", qos: .userInitiated)
        self.onUtterance = onUtterance
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
            if let utterance = segmenter.finish() {
                onUtterance(utterance)
            }
        }
    }

    private func processPendingWindows() {
        let size = SileroVAD.windowSize
        var start = 0
        while start + size <= pending.count {
            let window = Array(pending[start..<(start + size)])
            start += size
            // A failed window counts as silence rather than stopping the transcript.
            let probability = (try? vad.speechProbability(window)) ?? 0
            if let utterance = segmenter.process(window, probability: probability) {
                onUtterance(utterance)
            }
        }
        pending.removeFirst(start)
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
