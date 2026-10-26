//
//  AppleSpeechEngine.swift
//  note taker
//

import AVFoundation
import CoreMedia
import Speech

/// On-device transcription with Apple's SpeechAnalyzer. Handles one language per run.
actor AppleSpeechEngine {
    func transcribe(
        fileURL: URL,
        language: AppleSpeechLanguage,
        onProgress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> [RawSegment] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
            throw TranscriptionError.appleLanguageUnsupported(language.displayName)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onProgress(.downloadingModel(0))
            try await request.downloadAndInstall()
        }

        onProgress(.transcribing)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var segments: [RawSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                // Each run of the text carries the audio time it was heard at.
                var words: [RawWord] = []
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    words.append(RawWord(
                        start: range.start.seconds,
                        end: range.end.seconds,
                        text: String(result.text[run.range].characters)
                    ))
                }
                segments.append(RawSegment(
                    start: result.range.start.seconds,
                    end: result.range.end.seconds,
                    text: text,
                    words: words
                ))
            }
            return segments
        }

        let file = try AVAudioFile(forReading: fileURL)
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}
