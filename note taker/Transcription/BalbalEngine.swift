//
//  BalbalEngine.swift
//  note taker
//

import Foundation

/// Turkish only, on the CPU via balbal-v1. Small (about 200 MB of RAM) and fast, but poor
/// at English. Also the Turkish half of `BilingualEngine`.
actor BalbalEngine: SpeechEngine {
    private let folder: URL
    private var model: BalbalModel?

    init(modelsURL: URL) {
        folder = modelsURL.appendingPathComponent("balbal-v1", isDirectory: true)
    }

    func prepare(onProgress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws {
        _ = try await loadModel(onProgress: onProgress)
    }

    nonisolated func makeStream(wordTimings: Bool) -> any SpeechStream {
        Stream(engine: self)
    }

    private nonisolated struct Stream: SpeechStream {
        let engine: BalbalEngine

        func transcribe(_ utterance: Utterance) async throws -> [RawSegment] {
            try await engine.transcribeScored(utterance).segments
        }
    }

    /// The lines for one utterance, and how sure the model was of them (0 to 1).
    func transcribeScored(_ utterance: Utterance) async throws -> (segments: [RawSegment], confidence: Float) {
        let model = try await loadModel(onProgress: { _ in })
        let result = try model.transcribe(utterance.samples)
        guard !result.text.isEmpty else { return ([], 0) }
        let words = result.words.map {
            RawWord(start: utterance.start + $0.start, end: utterance.start + $0.end, text: $0.text)
        }
        let segment = RawSegment(start: utterance.start, end: utterance.end, text: result.text, words: words)
        return ([segment], result.confidence)
    }

    private func loadModel(
        onProgress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> BalbalModel {
        if let model { return model }
        if !BalbalModel.isDownloaded(in: folder) {
            onProgress(.downloadingModel(0))
            try await BalbalModel.download(to: folder) { onProgress(.downloadingModel($0)) }
        }
        onProgress(.loadingModel)
        let model = try BalbalModel(folder: folder)
        self.model = model
        return model
    }
}
