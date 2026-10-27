//
//  WhisperEngine.swift
//  note taker
//

import CoreML
import Foundation
import WhisperKit

/// On-device Whisper via WhisperKit. Detects the language per utterance, so a recording
/// that switches between Turkish and English is handled.
actor WhisperEngine: SpeechEngine {
    static let modelVariant = "openai_whisper-large-v3-v20240930_turbo"

    private let modelsURL: URL
    private var pipe: WhisperKit?

    init(modelsURL: URL) {
        self.modelsURL = modelsURL
    }

    func prepare(onProgress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws {
        _ = try await loadPipe(onProgress: onProgress)
    }

    nonisolated func makeStream(wordTimings: Bool) -> any SpeechStream {
        Stream(engine: self, wordTimings: wordTimings)
    }

    private nonisolated struct Stream: SpeechStream {
        let engine: WhisperEngine
        let wordTimings: Bool

        func transcribe(_ utterance: Utterance) async throws -> [RawSegment] {
            try await engine.transcribe(utterance, wordTimings: wordTimings)
        }
    }

    /// Utterances come from the VAD and are at most 20 s, so each one is a single Whisper
    /// window with no silence in it.
    func transcribe(_ utterance: Utterance, wordTimings: Bool) async throws -> [RawSegment] {
        let pipe = try await loadPipe(onProgress: { _ in })

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = nil
        options.detectLanguage = true
        options.skipSpecialTokens = true
        options.wordTimestamps = wordTimings

        let results = try await pipe.transcribe(audioArray: utterance.samples, decodeOptions: options)
        let offset = utterance.start
        return results.flatMap(\.segments).compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !Self.isKnownHallucination(text) else { return nil }
            let words = (segment.words ?? []).map {
                RawWord(start: offset + TimeInterval($0.start), end: offset + TimeInterval($0.end), text: $0.word)
            }
            return RawSegment(
                start: offset + TimeInterval(segment.start),
                end: offset + TimeInterval(segment.end),
                text: text,
                words: words
            )
        }
    }

    /// Lines Whisper is known to make up from noise, learned from subtitled videos.
    private static let hallucinations: Set<String> = [
        "altyazı m k",
        "abone olmayı unutmayın",
        "izlediğiniz için teşekkürler",
        "thank you for watching",
        "thanks for watching",
        "subtitles by the amara org community",
    ]

    private static func isKnownHallucination(_ text: String) -> Bool {
        let words = text.lowercased(with: Locale(identifier: "tr_TR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return hallucinations.contains(words.joined(separator: " "))
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
