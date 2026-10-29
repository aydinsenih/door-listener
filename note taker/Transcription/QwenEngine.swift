//
//  QwenEngine.swift
//  note taker
//

import Foundation
import Qwen3ASR

/// On-device Qwen3-ASR via speech-swift (MLX on the GPU). Detects the language per
/// utterance like Whisper does. It gives no word timings, so each utterance is one line.
actor QwenEngine: SpeechEngine {
    nonisolated enum Size: Sendable {
        /// 0.6B, 4-bit. About 0.65 GB.
        case small
        /// 1.7B, 8-bit. About 2.3 GB, more accurate.
        case large

        var modelId: String {
            switch self {
            case .small: Qwen3ASRModel.defaultModelId
            case .large: Qwen3ASRModel.largeModelId
            }
        }
    }

    private let size: Size
    private let modelsURL: URL
    private var model: Qwen3ASRModel?

    init(size: Size, modelsURL: URL) {
        self.size = size
        self.modelsURL = modelsURL
    }

    func prepare(onProgress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws {
        _ = try await loadModel(onProgress: onProgress)
    }

    nonisolated func makeStream(wordTimings: Bool) -> any SpeechStream {
        Stream(engine: self)
    }

    private nonisolated struct Stream: SpeechStream {
        let engine: QwenEngine

        func transcribe(_ utterance: Utterance) async throws -> [RawSegment] {
            try await engine.transcribe(utterance)
        }
    }

    /// Utterances come from the VAD and are at most 20 s, with the silence already cut.
    func transcribe(_ utterance: Utterance) async throws -> [RawSegment] {
        let model = try await loadModel(onProgress: { _ in })
        let raw = try model.transcribeThrowing(
            audio: utterance.samples,
            sampleRate: Int(SpeechSegmenter.sampleRate),
            options: Qwen3DecodingOptions(language: nil)
        )
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [RawSegment(start: utterance.start, end: utterance.end, text: text)]
    }

    private func loadModel(
        onProgress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> Qwen3ASRModel {
        if let model { return model }

        let folder = modelsURL
            .appendingPathComponent("qwen3-asr", isDirectory: true)
            .appendingPathComponent(Qwen3ASRModel.sanitizedCacheKey(for: size.modelId), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        onProgress(.downloadingModel(0))
        let model = try await Qwen3ASRModel.fromPretrained(
            modelId: size.modelId,
            cacheDir: folder,
            progressHandler: { fraction, _ in
                // speech-swift spends 0-80% downloading, the rest loading weights.
                if fraction < 0.8 {
                    onProgress(.downloadingModel(fraction / 0.8))
                } else {
                    onProgress(.loadingModel)
                }
            }
        )
        self.model = model
        return model
    }
}
