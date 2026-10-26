//
//  MicrophoneRecorder.swift
//  note taker
//

import AVFoundation

/// Records the default input device (the user's microphone) to a file.
nonisolated final class MicrophoneRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?

    func start(writingTo url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        let writer = try AudioFileWriter(url: url, format: format, label: "mic")
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            writer.append(buffer)
        }
        self.writer = writer

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            writer.close()
            self.writer = nil
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.close()
        writer = nil
    }
}
