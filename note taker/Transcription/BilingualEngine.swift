//
//  BilingualEngine.swift
//  note taker
//

import Foundation
import NemotronStreamingASR
import SpeechLanguageID

/// Turkish and English with two specialist models: each utterance goes to balbal (Turkish)
/// or Nemotron 3.5 streaming pinned to English, picked by a small language ID model (SpeechBrain
/// VoxLingua107). When language ID isn't sure, both models run and the more confident wins.
actor BilingualEngine: SpeechEngine {
    /// Language ID needs a couple of seconds of speech to be reliable.
    private static let minimumIdentifiedDuration: TimeInterval = 2
    /// Share of the Turkish-or-English probability the winner needs to be trusted alone.
    private static let minimumLanguageShare: Float = 0.8

    private let turkish: BalbalEngine
    private let modelsURL: URL
    private var english: NemotronStreamingASRModel?
    private var languageID: SpeechLanguageIdentifier?

    init(turkish: BalbalEngine, modelsURL: URL) {
        self.turkish = turkish
        self.modelsURL = modelsURL
    }

    func prepare(onProgress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws {
        // Three downloads; each one reports its own share of the bar.
        try await turkish.prepare { progress in
            if case let .downloadingModel(fraction) = progress {
                onProgress(.downloadingModel(fraction * 0.1))
            }
        }
        _ = try await loadLanguageID { onProgress(.downloadingModel(0.1 + $0 * 0.1)) }
        _ = try await loadEnglish { onProgress(.downloadingModel(0.2 + $0 * 0.8)) }
        onProgress(.loadingModel)
    }

    nonisolated func makeStream(wordTimings: Bool) -> any SpeechStream {
        Stream(engine: self)
    }

    private nonisolated struct Stream: SpeechStream {
        let engine: BilingualEngine

        func transcribe(_ utterance: Utterance) async throws -> [RawSegment] {
            try await engine.transcribe(utterance)
        }
    }

    private enum Language { case turkish, english }

    func transcribe(_ utterance: Utterance) async throws -> [RawSegment] {
        switch try await identify(utterance) {
        case .turkish:
            return try await turkish.transcribeScored(utterance).segments
        case .english:
            return try await transcribeEnglish(utterance).segments
        case nil:
            let tr = try await turkish.transcribeScored(utterance)
            let en = try await transcribeEnglish(utterance)
            return tr.confidence >= en.confidence ? tr.segments : en.segments
        }
    }

    /// Turkish or English, or nil when the utterance is too short or language ID is unsure.
    private func identify(_ utterance: Utterance) async throws -> Language? {
        guard utterance.duration >= Self.minimumIdentifiedDuration else { return nil }
        let model = try await loadLanguageID { _ in }
        guard let result = try? model.identify(
            audio: utterance.samples,
            sampleRate: Int(SpeechSegmenter.sampleRate),
            topK: model.labels.count
        ) else { return nil }
        let probability = { (code: String) in
            result.predictions.first { $0.label.code == code }?.probability ?? 0
        }
        let tr = probability("tr"), en = probability("en")
        guard tr + en > 0 else { return nil }
        if tr / (tr + en) >= Self.minimumLanguageShare { return .turkish }
        if en / (tr + en) >= Self.minimumLanguageShare { return .english }
        return nil
    }

    private func transcribeEnglish(_ utterance: Utterance) async throws -> (segments: [RawSegment], confidence: Float) {
        let model = try await loadEnglish { _ in }
        // Pinned to English: the language slot is one-hot, so it can't wander into other
        // languages the way auto mode did.
        let session = try model.createSession(language: "en-US")
        // A little silence on both ends primes the streaming encoder's cache, so the first
        // word isn't lost.
        let padding = [Float](repeating: 0, count: Int(Self.englishPadding * SpeechSegmenter.sampleRate))
        var partials = try session.pushAudio(padding + utterance.samples + padding)
        partials += try session.finalize()
        guard let result = partials.last(where: \.isFinal) ?? partials.last else { return ([], 0) }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ([], 0) }
        let words = result.words.map { word in
            RawWord(
                start: utterance.start + max(0, word.startTime - Self.englishPadding),
                end: utterance.start + max(0, word.endTime - Self.englishPadding),
                text: " " + word.text
            )
        }
        let segment = RawSegment(start: utterance.start, end: utterance.end, text: text, words: words)
        return ([segment], result.confidence)
    }

    private static let englishPadding: TimeInterval = 0.1

    private func loadEnglish(onProgress: @escaping @Sendable (Double) -> Void) async throws -> NemotronStreamingASRModel {
        if let english { return english }
        // speech-swift keeps this one in its own cache, ~/Library/Caches/qwen3-speech.
        let model = try await NemotronStreamingASRModel.fromPretrained(
            progressHandler: { fraction, _ in onProgress(fraction) }
        )
        // Core ML compiles the model on its first prediction; do it now, not mid-meeting.
        try? model.warmUp()
        english = model
        return model
    }

    private func loadLanguageID(onProgress: @escaping @Sendable (Double) -> Void) async throws -> SpeechLanguageIdentifier {
        if let languageID { return languageID }
        let modelId = SpeechLanguageIdentifier.defaultMLXModelID
        let folder = try cacheFolder("language-id", modelId: modelId)
        let model = try await SpeechLanguageIdentifier.fromPretrained(
            modelID: modelId,
            engine: .mlx,
            cacheDir: folder,
            progressHandler: { fraction, _ in onProgress(fraction) }
        )
        languageID = model
        return model
    }

    private func cacheFolder(_ name: String, modelId: String) throws -> URL {
        let folder = modelsURL
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(modelId.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
