//
//  AppleSpeechEngine.swift
//  note taker
//

import AVFoundation
import CoreMedia
import Speech

/// On-device transcription with Apple's SpeechAnalyzer. Handles one language per engine.
actor AppleSpeechEngine: SpeechEngine {
    let language: AppleSpeechLanguage
    private var locale: Locale?
    private var analyzerFormat: AVAudioFormat?

    init(language: AppleSpeechLanguage) {
        self.language = language
    }

    func prepare(onProgress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws {
        guard locale == nil else { return }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
            throw TranscriptionError.appleLanguageUnsupported(language.displayName)
        }

        let transcriber = Self.makeTranscriber(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onProgress(.downloadingModel(0))
            try await request.downloadAndInstall()
        }
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.locale = locale
    }

    nonisolated func makeStream(wordTimings: Bool) -> any SpeechStream {
        Stream(engine: self)
    }

    private nonisolated struct Stream: SpeechStream {
        let engine: AppleSpeechEngine

        func transcribe(_ utterance: Utterance) async throws -> [RawSegment] {
            try await engine.transcribe(utterance)
        }
    }

    func transcribe(_ utterance: Utterance) async throws -> [RawSegment] {
        try await prepare(onProgress: { _ in })
        guard let locale, let input = Self.buffer(utterance.samples, convertedTo: analyzerFormat) else { return [] }

        let transcriber = Self.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let offset = utterance.start
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
                        start: offset + range.start.seconds,
                        end: offset + range.end.seconds,
                        text: String(result.text[run.range].characters)
                    ))
                }
                segments.append(RawSegment(
                    start: offset + result.range.start.seconds,
                    end: offset + result.range.end.seconds,
                    text: text,
                    words: words
                ))
            }
            return segments
        }

        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: input))
        continuation.finish()
        if let lastSample = try await analyzer.analyzeSequence(inputs) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Puts 16 kHz mono samples into a buffer in the format the analyzer wants.
    private static func buffer(_ samples: [Float], convertedTo format: AVAudioFormat?) -> AVAudioPCMBuffer? {
        let speechFormat = LiveTrackProcessor.speechFormat
        guard !samples.isEmpty,
              let source = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        source.frameLength = source.frameCapacity
        samples.withUnsafeBufferPointer { source.floatChannelData?[0].update(from: $0.baseAddress!, count: samples.count) }

        guard let format, format != speechFormat else { return source }
        guard let converter = AVAudioConverter(from: speechFormat, to: format),
              let output = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(Double(samples.count) * format.sampleRate / speechFormat.sampleRate) + 32
              )
        else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return source
        }
        return status == .error ? nil : output
    }
}
