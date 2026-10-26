//
//  RecordingStore.swift
//  note taker
//

import AppKit
import AVFoundation
import Observation

/// Starts and stops recordings and keeps the list of saved sessions.
@Observable
final class RecordingStore {
    private(set) var sessions: [RecordingSession] = []
    private(set) var activeSession: RecordingSession?
    private(set) var isStarting = false
    var errorMessage: String?

    var isRecording: Bool { activeSession != nil }

    static let echoCancellationKey = "echoCancellation"

    @ObservationIgnored private var microphone: MicrophoneRecorder?
    @ObservationIgnored private var systemAudio: SystemAudioRecorder?
    @ObservationIgnored let rootURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootURL = appSupport
            .appendingPathComponent("Door Listener", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        loadSessions()
    }

    func folderURL(for session: RecordingSession) -> URL {
        rootURL.appendingPathComponent(session.folderName, isDirectory: true)
    }

    func toggle() {
        if isRecording {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = RecorderError.microphonePermissionDenied.localizedDescription
            return
        }

        let startedAt = Date.now
        let session = RecordingSession(
            id: UUID(),
            folderName: Self.folderName(for: startedAt),
            startedAt: startedAt,
            hasMicrophone: false,
            hasSystemAudio: false
        )
        let folder = folderURL(for: session)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        var started = session
        var problems: [String] = []

        // System audio starts first: turning on the mic's voice processing reconfigures
        // the output device, and the tap has to be in place before that happens.
        let systemAudio = SystemAudioRecorder()
        do {
            try systemAudio.start(writingTo: folder.appendingPathComponent(RecordingSession.systemFileName))
            self.systemAudio = systemAudio
            started.hasSystemAudio = true
        } catch {
            problems.append("System audio: \(error.localizedDescription)")
        }

        let microphone = MicrophoneRecorder()
        do {
            try microphone.start(
                writingTo: folder.appendingPathComponent(RecordingSession.micFileName),
                echoCancellation: UserDefaults.standard.object(forKey: Self.echoCancellationKey) as? Bool ?? false
            )
            self.microphone = microphone
            started.hasMicrophone = true
        } catch {
            problems.append("Microphone: \(error.localizedDescription)")
        }

        if !problems.isEmpty {
            errorMessage = problems.joined(separator: "\n\n")
        }
        guard started.hasMicrophone || started.hasSystemAudio else {
            try? FileManager.default.removeItem(at: folder)
            return
        }

        activeSession = started
        save(started)
    }

    func stop() {
        guard var session = activeSession else { return }
        microphone?.stop()
        systemAudio?.stop()
        microphone = nil
        systemAudio = nil

        session.endedAt = .now
        save(session)
        activeSession = nil
        sessions.insert(session, at: 0)
    }

    func revealInFinder(_ session: RecordingSession) {
        NSWorkspace.shared.activateFileViewerSelecting([folderURL(for: session)])
    }

    func moveToTrash(_ session: RecordingSession) {
        do {
            try FileManager.default.trashItem(at: folderURL(for: session), resultingItemURL: nil)
            sessions.removeAll { $0.id == session.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(_ session: RecordingSession) {
        let url = folderURL(for: session).appendingPathComponent(RecordingSession.metadataFileName)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(session).write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSessions() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        sessions = folders
            .compactMap { folder in
                let url = folder.appendingPathComponent(RecordingSession.metadataFileName)
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(RecordingSession.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private static func folderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: date)
    }
}
