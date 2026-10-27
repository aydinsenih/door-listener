//
//  TranscriptMerger.swift
//  note taker
//

import Foundation

/// Combines the mic and system transcripts into one timeline.
nonisolated enum TranscriptMerger {
    static let meLabel = "Me"
    static let othersLabel = "Others"

    static func speakerLabel(_ number: Int) -> String { "Speaker \(number)" }

    /// Mic segments that repeat what the system track said at the same time are speaker
    /// bleed (the mic hearing the call through the speakers), so they're dropped.
    /// System segments get "Speaker N" from `speakerTurns`, or "Others" when it's nil.
    static func merge(
        mic: [RawSegment],
        system: [RawSegment],
        speakerTurns: [SpeakerTurn]?
    ) -> [TranscriptSegment] {
        let keptMic = mic.filter { !isBleed($0, system: system) }

        let systemSegments: [TranscriptSegment]
        if let speakerTurns {
            systemSegments = system.flatMap { assignSpeakers(to: $0, turns: speakerTurns) }
        } else {
            systemSegments = system.map {
                TranscriptSegment(start: $0.start, end: $0.end, speaker: othersLabel, text: $0.text)
            }
        }

        let segments = keptMic.map {
            TranscriptSegment(start: $0.start, end: $0.end, speaker: meLabel, text: $0.text)
        } + systemSegments
        return segments.sorted { $0.start < $1.start }
    }

    /// Labels a system segment with the speaker talking at that time. With word timings,
    /// the segment is split wherever the speaker changes mid-sentence.
    static func assignSpeakers(to segment: RawSegment, turns: [SpeakerTurn]) -> [TranscriptSegment] {
        guard !segment.words.isEmpty else {
            let speaker = dominantSpeaker(from: segment.start, to: segment.end, turns: turns) ?? 1
            return [TranscriptSegment(
                start: segment.start, end: segment.end,
                speaker: speakerLabel(speaker), text: segment.text
            )]
        }

        var pieces: [(speaker: Int, words: [RawWord])] = []
        for word in segment.words {
            // Words between turns stay with whoever was talking just before.
            let speaker = dominantSpeaker(from: word.start, to: word.end, turns: turns)
                ?? pieces.last?.speaker
                ?? dominantSpeaker(from: segment.start, to: segment.end, turns: turns)
                ?? 1
            if pieces.last?.speaker == speaker {
                pieces[pieces.count - 1].words.append(word)
            } else {
                pieces.append((speaker, [word]))
            }
        }

        return pieces.compactMap { piece in
            let text = piece.words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let first = piece.words.first, let last = piece.words.last else { return nil }
            return TranscriptSegment(
                start: first.start, end: last.end,
                speaker: speakerLabel(piece.speaker), text: text
            )
        }
    }

    /// The speaker whose turns overlap the time range the most, if any overlap it.
    private static func dominantSpeaker(from start: TimeInterval, to end: TimeInterval, turns: [SpeakerTurn]) -> Int? {
        var overlapBySpeaker: [Int: TimeInterval] = [:]
        for turn in turns {
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > 0 {
                overlapBySpeaker[turn.speaker, default: 0] += overlap
            } else if start == end, turn.start <= start, start <= turn.end {
                // Some words come back with no duration; count them if they fall inside a turn.
                overlapBySpeaker[turn.speaker, default: 0] += 0.001
            }
        }
        return overlapBySpeaker.max { $0.value < $1.value }?.key
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
