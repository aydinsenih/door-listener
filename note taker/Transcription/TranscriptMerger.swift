//
//  TranscriptMerger.swift
//  note taker
//

import Foundation

/// Combines the mic and system transcripts into one timeline.
nonisolated enum TranscriptMerger {
    static let meLabel = "Me"
    static let othersLabel = "Others"

    /// Mic segments that repeat what the system track said at the same time are speaker
    /// bleed (the mic hearing the call through the speakers), so they're dropped.
    static func merge(mic: [RawSegment], system: [RawSegment]) -> [TranscriptSegment] {
        let keptMic = mic.filter { !isBleed($0, system: system) }

        let segments = keptMic.map {
            TranscriptSegment(start: $0.start, end: $0.end, speaker: meLabel, text: $0.text)
        } + system.map {
            TranscriptSegment(start: $0.start, end: $0.end, speaker: othersLabel, text: $0.text)
        }
        return segments.sorted { $0.start < $1.start }
    }

    /// How much timing slack to allow between the two tracks, in seconds.
    private static let timeTolerance: TimeInterval = 1.5
    /// Share of a mic segment's words that must also appear in overlapping system speech.
    private static let bleedWordShare = 0.6

    static func isBleed(_ segment: RawSegment, system: [RawSegment]) -> Bool {
        let micWords = words(in: segment.text)
        guard !micWords.isEmpty else { return true }

        let overlapping = system.filter {
            $0.start <= segment.end + timeTolerance && $0.end >= segment.start - timeTolerance
        }
        guard !overlapping.isEmpty else { return false }

        let systemWords = Set(overlapping.flatMap { words(in: $0.text) })
        let shared = micWords.filter { systemWords.contains($0) }.count
        return Double(shared) / Double(micWords.count) >= bleedWordShare
    }

    private static func words(in text: String) -> [String] {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
