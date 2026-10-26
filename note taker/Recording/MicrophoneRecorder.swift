//
//  MicrophoneRecorder.swift
//  note taker
//

import AVFoundation

/// Records the default input device (the user's microphone) to a file.
nonisolated final class MicrophoneRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?

    /// Starts recording. With `echoCancellation` on, macOS voice processing removes
    /// what the speakers play from the mic signal, so call audio doesn't bleed into "Me".
    /// `live` also gets every buffer, for transcribing while recording.
    func start(writingTo url: URL, echoCancellation: Bool, live: LiveTrackProcessor?) throws {
        let input = engine.inputNode
        if echoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Voice processing ducks other apps by default, which would make the call quieter.
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
            } catch {
                try? input.setVoiceProcessingEnabled(false)
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        // Voice processing can report several channels where only the first carries
        // the processed voice, so keep just that one.
        let keepFirstChannelOnly = input.isVoiceProcessingEnabled
            && format.channelCount > 1
            && format.commonFormat == .pcmFormatFloat32
            && !format.isInterleaved
        let fileFormat = keepFirstChannelOnly
            ? AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
            : format

        let writer = try AudioFileWriter(url: url, format: fileFormat, label: "mic")
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if keepFirstChannelOnly {
                if let mono = Self.firstChannel(of: buffer, as: fileFormat) {
                    writer.append(mono)
                    live?.append(mono)
                }
            } else {
                writer.append(buffer)
                live?.append(buffer)
            }
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

    private static func firstChannel(of buffer: AVAudioPCMBuffer, as format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData
        else { return nil }
        mono.frameLength = buffer.frameLength
        destination[0].update(from: source[0], count: Int(buffer.frameLength))
        return mono
    }
}
