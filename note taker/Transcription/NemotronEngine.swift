//
//  NemotronEngine.swift
//  note taker
//

import FluidAudio
import Foundation

/// NVIDIA Nemotron 3.5 ASR Streaming Multilingual (0.6B) on the Neural Engine, via
/// FluidAudio. It streams natively, so text shows up while someone is still talking.
/// Detects the language itself, which suits Turkish and English mixed in one call.
/// Needs Apple Silicon; the model is about 665 MB, downloaded the first time.
actor NemotronEngine: SpeechEngine {
    /// 1120 ms chunks had the lowest error rate of the published sizes.
    static let chunkMs = 1120

    private let modelsURL: URL
    private var models: SharedNemotronMultilingualModels?

    init(modelsURL: URL) {
        self.modelsURL = modelsURL
    }

    func prepare(onProgress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws {
        guard models == nil else { return }
        onProgress(.downloadingModel(0))
        let folder = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "auto",
            chunkMs: Self.chunkMs,
            to: modelsURL,
            progressHandler: { progress in
                onProgress(.downloadingModel(progress.fractionCompleted))
            }
        )
        onProgress(.loadingModel)
        models = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: folder)
    }

    nonisolated func makeStream(wordTimings: Bool) -> any SpeechStream {
        Stream(engine: self)
    }

    /// One decoder per track. The model weights are loaded once and shared.
    fileprivate func makeManager() async throws -> StreamingNemotronMultilingualAsrManager {
        try await prepare(onProgress: { _ in })
        guard let models else { throw TranscriptionError.modelUnavailable }
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadFromShared(models)
        return manager
    }

    /// Each utterance is its own decoding session: fed while it's said, finished at the pause.
    private actor Stream: SpeechStream {
        nonisolated let isStreaming = true
        private let engine: NemotronEngine
        private var manager: StreamingNemotronMultilingualAsrManager?
        /// Where the audio of the current session starts in the track, once fed.
        private var sessionStart: TimeInterval?

        init(engine: NemotronEngine) {
            self.engine = engine
        }

        func feed(_ samples: [Float], at time: TimeInterval) async throws -> String {
            let manager = try await loadManager()
            if sessionStart == nil {
                await manager.reset()
                sessionStart = time
            }
            _ = try await manager.process(samples: samples)
            return await manager.getPartialTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func discard() async {
            // The next feed starts a fresh session.
            sessionStart = nil
        }

        func transcribe(_ utterance: Utterance) async throws -> [RawSegment] {
            let manager = try await loadManager()
            if sessionStart == nil {
                // Not streamed, for example a saved file: feed the whole utterance now.
                await manager.reset()
                sessionStart = utterance.start
                _ = try await manager.process(samples: utterance.samples)
            }
            let start = sessionStart ?? utterance.start
            sessionStart = nil

            let (text, timings) = try await manager.finishWithTokenTimings()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            // Words keep a leading space, so joining them gives back the text.
            let words = buildWordTimings(from: timings).map {
                RawWord(start: start + $0.startTime, end: start + $0.endTime, text: " " + $0.word)
            }
            return [RawSegment(
                start: words.first?.start ?? utterance.start,
                end: words.last?.end ?? utterance.end,
                text: trimmed,
                words: words
            )]
        }

        private func loadManager() async throws -> StreamingNemotronMultilingualAsrManager {
            if let manager { return manager }
            let manager = try await engine.makeManager()
            self.manager = manager
            return manager
        }
    }
}
