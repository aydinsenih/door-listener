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
    /// Word timings, used to split a segment where the speaker changes. Text keeps its
    /// own leading spaces, so joining the words gives back the segment text.
    var words: [RawWord] = []
}

nonisolated struct RawWord: Sendable {
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
    /// Set when the system track couldn't be split into speakers, so it's labeled "Others".
    var speakerError: String?

    /// Back-to-back segments from the same speaker, joined into one line each.
    var turns: [TranscriptSegment] {
        var turns: [TranscriptSegment] = []
        for segment in segments {
            if var last = turns.last, last.speaker == segment.speaker, segment.start - last.end < Self.turnGap {
                last.end = max(last.end, segment.end)
                last.text += " " + segment.text
                turns[turns.count - 1] = last
            } else {
                turns.append(segment)
            }
        }
        return turns
    }

    /// Distinct speaker labels, in order of first appearance.
    var speakers: [String] {
        var seen: [String] = []
        for segment in segments where !seen.contains(segment.speaker) {
            seen.append(segment.speaker)
        }
        return seen
    }

    /// A pause longer than this starts a new line even if the speaker didn't change.
    private static let turnGap: TimeInterval = 8

    var plainText: String {
        turns
            .map { "[\(Self.timestamp($0.start))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n\n")
    }

    func markdown(title: String) -> String {
        let body = turns
            .map { "**\($0.speaker)** · \(Self.timestamp($0.start))  \n\($0.text)" }
            .joined(separator: "\n\n")
        return "# \(title)\n\n\(body)\n"
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
