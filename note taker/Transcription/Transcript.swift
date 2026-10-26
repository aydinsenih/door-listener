//
//  Transcript.swift
//  note taker
//

import Foundation

nonisolated enum TranscriptionEngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case whisper
    case apple

    static let settingsKey = "transcriptionEngine"
    static let `default`: TranscriptionEngineKind = .whisper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper: "Whisper (mixed Turkish and English)"
        case .apple: "Apple Speech (one language)"
        }
    }
}

/// Languages offered for Apple Speech, which transcribes one language per recording.
nonisolated enum AppleSpeechLanguage: String, CaseIterable, Identifiable, Sendable {
    case turkish = "tr-TR"
    case english = "en-US"

    static let settingsKey = "appleSpeechLanguage"
    static let `default`: AppleSpeechLanguage = .turkish

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    var displayName: String {
        switch self {
        case .turkish: "Turkish"
        case .english: "English"
        }
    }
}

/// A timed piece of text from one track, before speakers are assigned.
nonisolated struct RawSegment: Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

nonisolated struct TranscriptSegment: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var speaker: String
    var text: String
}

/// Saved next to the audio as `transcript.json`.
nonisolated struct Transcript: Codable, Sendable {
    static let fileName = "transcript.json"

    var engine: TranscriptionEngineKind
    var language: String?
    var createdAt: Date
    var segments: [TranscriptSegment]

    var plainText: String {
        segments
            .map { "[\(Self.timestamp($0.start))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

nonisolated enum TranscriptionError: LocalizedError {
    case appleLanguageUnsupported(String)
    case noAudio

    var errorDescription: String? {
        switch self {
        case let .appleLanguageUnsupported(language):
            "Apple Speech doesn't support \(language) on this Mac. Switch to Whisper in Settings."
        case .noAudio:
            "This recording has no audio tracks to transcribe."
        }
    }
}
