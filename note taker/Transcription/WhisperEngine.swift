//
//  WhisperEngine.swift
//  note taker
//

import CoreML
import Foundation
import WhisperKit

/// On-device Whisper via WhisperKit. Detects the language per chunk, so a recording
/// that switches between Turkish and English is handled.
actor WhisperEngine {
    static let modelVariant = "openai_whisper-large-v3-v20240930_turbo"

    private let modelsURL: URL
    private var pipe: WhisperKit?

    init(modelsURL: URL) {
        self.modelsURL = modelsURL
    }

    func transcribe(
        fileURL: URL,
        onProgress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> [RawSegment] {
        let pipe = try await loadPipe(onProgress: onProgress)
        onProgress(.transcribing)

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = nil
        options.detectLanguage = true
        options.skipSpecialTokens = true
        options.chunkingStrategy = .vad

        let results = try await pipe.transcribe(audioPath: fileURL.path, decodeOptions: options)
        return results.flatMap(\.segments).compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RawSegment(start: TimeInterval(segment.start), end: TimeInterval(segment.end), text: text)
        }
    }

    private func loadPipe(
        onProgress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> WhisperKit {
        if let pipe { return pipe }

        onProgress(.downloadingModel(0))
        let modelFolder = try await WhisperKit.download(
            variant: Self.modelVariant,
            downloadBase: modelsURL,
            progressCallback: { progress in
                onProgress(.downloadingModel(progress.fractionCompleted))
            }
        )

        onProgress(.loadingModel)
        // Run on the GPU. The Neural Engine default makes macOS compile the large model
        // for it on first load, which can take many minutes and looks like a hang.
        let config = WhisperKitConfig(
            downloadBase: modelsURL,
            modelFolder: modelFolder.path,
            computeOptions: ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU
            ),
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        let pipe = try await WhisperKit(config)
        self.pipe = pipe
        return pipe
    }
}
