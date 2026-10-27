//
//  NemotronEngine.swift
//  note taker
//

import FluidAudio
import Foundation

/// NVIDIA Nemotron 3.5 ASR Streaming Multilingual (0.6B) on the Neural Engine, via
/// FluidAudio. It streams natively, so text shows up while someone is still talking.
/// Needs Apple Silicon; the model is about 665 MB, downloaded the first time.
///
/// The model's own language detection ("auto") drifts between languages mid-sentence,
/// so the saved text always comes from a decoder pinned to Turkish or English.
actor NemotronEngine: SpeechEngine {
    /// 1120 ms chunks had the lowest error rate of the published sizes.
    static let chunkMs = 1120

    nonisolated let languages: NemotronLanguage
    private let modelsURL: URL
    private var models: SharedNemotronMultilingualModels?

    init(modelsURL: URL, languages: NemotronLanguage) {
        self.modelsURL = modelsURL
        self.languages = languages
    }

    func prepare(onProgress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws {
        guard models == nil else { return }
        onProgress(.downloadingModel(0))
        // The full multilingual ship; the smaller "latin" one has no Turkish.
        let folder = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "auto",
            chunkMs: Self.chunkMs,
            to: modelsURL,
            progressHandler: { progress in
                onProgress(.downloadingModel(progress.fractionCompleted))
            }
        )
        onProgress(.loadingModel)
        let models = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: folder)
        // An unknown code silently falls back to "auto", which is the drift we're avoiding.
        for code in languages.codes where models.config.promptId(forLanguage: code) == models.config.defaultPromptId {
            throw TranscriptionError.nemotronLanguageUnsupported(code)
        }
        self.models = models
    }

    nonisolated func makeStream(wordTimings: Bool) -> any SpeechStream {
        Stream(engine: self)
    }

    /// A decoder pinned to one language code ("auto" lets the model pick). The model
    /// weights are loaded once and shared; each decoder keeps its own state.
    fileprivate func makeManager(language code: String) async throws -> StreamingNemotronMultilingualAsrManager {
        try await prepare(onProgress: { _ in })
        guard let models else { throw TranscriptionError.modelUnavailable }
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadFromShared(models)
        await manager.setLanguage(code)
        return manager
    }

    /// Each utterance is its own decoding session: fed while it's said, finished at the pause.
    ///
    /// With one language, a decoder pinned to it streams the text. With Turkish and English,
    /// an "auto" decoder streams the text shown while someone talks and names the language
    /// it heard first; at the pause the utterance is decoded again pinned to that language
    /// (English if it heard English, otherwise Turkish), so the saved line can't drift.
    private actor Stream: SpeechStream {
        nonisolated let isStreaming = true
        private let engine: NemotronEngine
        /// Streams the utterance: pinned with one language, "auto" with both.
        private var live: StreamingNemotronMultilingualAsrManager?
        private var turkish: StreamingNemotronMultilingualAsrManager?
        private var english: StreamingNemotronMultilingualAsrManager?
        /// Where the audio of the current session starts in the track, once fed.
        private var sessionStart: TimeInterval?
        /// The session's audio, kept to decode it again pinned when both languages are on.
        private var sessionSamples: [Float] = []

        init(engine: NemotronEngine) {
            self.engine = engine
        }

        func feed(_ samples: [Float], at time: TimeInterval) async throws -> String {
            let live = try await liveManager()
            if sessionStart == nil {
                await live.reset()
                sessionStart = time
                sessionSamples = []
            }
            if engine.languages == .turkishAndEnglish {
                sessionSamples.append(contentsOf: samples)
            }
            _ = try await live.process(samples: samples)
            return await live.getPartialTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func discard() async {
            // The next feed starts a fresh session.
            sessionStart = nil
            sessionSamples = []
        }

        func transcribe(_ utterance: Utterance) async throws -> [RawSegment] {
            if sessionStart == nil {
                // Not streamed, for example a saved file: feed the whole utterance now.
                _ = try await feed(utterance.samples, at: utterance.start)
            }
            let start = sessionStart ?? utterance.start
            let samples = sessionSamples
            sessionStart = nil
            sessionSamples = []

            let live = try await liveManager()
            var (text, timings) = try await live.finishWithTokenTimings()
            if engine.languages == .turkishAndEnglish {
                let heard = await live.detectedLanguage() ?? ""
                let pinned = try await pinnedManager(english: heard.lowercased().hasPrefix("en"))
                await pinned.reset()
                _ = try await pinned.process(samples: samples)
                (text, timings) = try await pinned.finishWithTokenTimings()
            }

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

        private func liveManager() async throws -> StreamingNemotronMultilingualAsrManager {
            if let live { return live }
            let manager = try await engine.makeManager(language: engine.languages.streamingCode)
            live = manager
            return manager
        }

        private func pinnedManager(english: Bool) async throws -> StreamingNemotronMultilingualAsrManager {
            if english, let manager = self.english { return manager }
            if !english, let manager = turkish { return manager }
            let manager = try await engine.makeManager(language: english ? "en-US" : "tr-TR")
            if english { self.english = manager } else { turkish = manager }
            return manager
        }
    }
}
