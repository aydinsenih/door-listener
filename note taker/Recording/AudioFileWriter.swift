//
//  AudioFileWriter.swift
//  note taker
//

import AVFoundation

/// Writes PCM buffers to an AAC (.m4a) file on a background queue.
///
/// Audio callbacks hand us buffers that are only valid for the duration of the
/// callback, so each buffer is copied before it is queued for encoding.
nonisolated final class AudioFileWriter: @unchecked Sendable {
    private let file: AVAudioFile
    private let queue: DispatchQueue
    private var isClosed = false

    init(url: URL, format: AVAudioFormat, label: String) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: format.isInterleaved
        )
        queue = DispatchQueue(label: "AudioFileWriter.\(label)", qos: .userInitiated)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.copied() else { return }
        queue.async { [self] in
            guard !isClosed else { return }
            try? file.write(from: copy)
        }
    }

    /// Flushes pending buffers and finalizes the file.
    func close() {
        queue.sync {
            isClosed = true
            file.close()
        }
    }
}

nonisolated extension AVAudioPCMBuffer {
    /// A copy that stays valid after an audio callback returns.
    func copied() -> AVAudioPCMBuffer? {
        let frames = frameLength
        guard frames > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        copy.frameLength = frames

        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(source, destination) {
            guard let srcData = src.mData, let dstData = dst.mData else { continue }
            memcpy(dstData, srcData, Int(min(src.mDataByteSize, dst.mDataByteSize)))
        }
        return copy
    }
}
