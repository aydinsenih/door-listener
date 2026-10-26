//
//  SpeakerDiarizer.swift
//  note taker
//

import Foundation
import SpeakerKit
import WhisperKit

/// A stretch of the system track where one speaker is talking.
nonisolated struct SpeakerTurn: Sendable {
    var start: TimeInterval
    var end: TimeInterval
    /// 1 for the first voice heard, 2 for the next new voice, and so on.
    var speaker: Int
}

/// Finds who speaks when in the system track, on-device with SpeakerKit (Pyannote).
actor SpeakerDiarizer {
    private let modelsURL: URL
    private var kit: SpeakerKit?

    init(modelsURL: URL) {
        self.modelsURL = modelsURL
    }

    func diarize(
        fileURL: URL,
        onProgress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> [SpeakerTurn] {
        let kit = try await loadKit(onProgress: onProgress)
        onProgress(.identifyingSpeakers)

        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: fileURL.path)
        let result = try await kit.diarize(audioArray: audio)

        // SpeakerKit's ids are arbitrary, so number speakers by when they first talk.
        var numbers: [Int: Int] = [:]
        var turns: [SpeakerTurn] = []
        for segment in result.segments.sorted(by: { $0.startTime < $1.startTime }) {
            guard let id = segment.speaker.speakerId else { continue }
            let number = numbers[id] ?? numbers.count + 1
            numbers[id] = number
            turns.append(SpeakerTurn(
                start: TimeInterval(segment.startTime),
                end: TimeInterval(segment.endTime),
                speaker: number
            ))
        }
        return turns
    }

    private func loadKit(
        onProgress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> SpeakerKit {
        if let kit { return kit }
        // The models are small (tens of MB) and download the first time only.
        onProgress(.loadingSpeakerModel)
        let config = PyannoteConfig(downloadBase: modelsURL.path, verbose: false)
        let kit = try await SpeakerKit(config)
        try await kit.ensureModelsLoaded()
        self.kit = kit
        return kit
    }
}
