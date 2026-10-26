//
//  RecordingSession.swift
//  note taker
//

import Foundation

/// One recording, stored as a folder holding `mic.m4a`, `system.m4a` and `session.json`.
nonisolated struct RecordingSession: Codable, Identifiable, Hashable, Sendable {
    static let micFileName = "mic.m4a"
    static let systemFileName = "system.m4a"
    static let metadataFileName = "session.json"

    let id: UUID
    let folderName: String
    let startedAt: Date
    var endedAt: Date?
    var hasMicrophone: Bool
    var hasSystemAudio: Bool

    var duration: TimeInterval {
        (endedAt ?? .now).timeIntervalSince(startedAt)
    }
}
