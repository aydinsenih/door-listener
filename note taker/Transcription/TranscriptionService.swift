//
//  TranscriptionService.swift
//  note taker
//

import Foundation
import Observation

nonisolated enum TranscriptionProgress: Sendable, Equatable {
    case downloadingModel(Double)
    case loadingModel
    case transcribing
    case loadingSpeakerModel
    case identifyingSpeakers
}

/// Runs transcription for finished sessions and keeps their transcripts.
@Observable
final class TranscriptionService {
    enum Status: Equatable {
        case queued
        case working(track: String, progress: TranscriptionProgress)
        case failed(String)
    }

    private(set) var statuses: [UUID: Status] = [:]
    private(set) var transcripts: [UUID: Transcript] = [:]

    @ObservationIgnored private let whisper: WhisperEngine
    @ObservationIgnored private let diarizer: SpeakerDiarizer
    @ObservationIgnored private let apple = AppleSpeechEngine()
    @ObservationIgnored private var queue: [(RecordingSession, URL)] = []
    @ObservationIgnored private var isRunning = false

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let modelsURL = appSupport
            .appendingPathComponent("Door Listener", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsURL, withIntermediateDirectories: true)
        whisper = WhisperEngine(modelsURL: modelsURL)
        diarizer = SpeakerDiarizer(modelsURL: modelsURL)
    }

    var selectedEngine: TranscriptionEngineKind {
        UserDefaults.standard.string(forKey: TranscriptionEngineKind.settingsKey)
            .flatMap(TranscriptionEngineKind.init(rawValue:)) ?? .default
    }

    var selectedAppleLanguage: AppleSpeechLanguage {
        UserDefaults.standard.string(forKey: AppleSpeechLanguage.settingsKey)
            .flatMap(AppleSpeechLanguage.init(rawValue:)) ?? .default
    }

    /// Loads a saved transcript from disk if it isn't already in memory.
    func loadTranscript(for session: RecordingSession, in folder: URL) {
        guard transcripts[session.id] == nil else { return }
        let url = folder.appendingPathComponent(Transcript.fileName)
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        transcripts[session.id] = try? decoder.decode(Transcript.self, from: data)
    }

    func isBusy(_ session: RecordingSession) -> Bool {
        switch statuses[session.id] {
        case .queued, .working: true
        default: false
        }
    }

    func enqueue(_ session: RecordingSession, folder: URL) {
        guard !isBusy(session) else { return }
        statuses[session.id] = .queued
        queue.append((session, folder))
        if !isRunning {
            Task { await runQueue() }
        }
    }

    private func runQueue() async {
        isRunning = true
        defer { isRunning = false }
        while !queue.isEmpty {
            let (session, folder) = queue.removeFirst()
            do {
                let transcript = try await transcribe(session, folder: folder)
                try save(transcript, in: folder)
                transcripts[session.id] = transcript
                statuses[session.id] = nil
            } catch {
                statuses[session.id] = .failed(error.localizedDescription)
            }
        }
    }

    private func transcribe(_ session: RecordingSession, folder: URL) async throws -> Transcript {
        guard session.hasMicrophone || session.hasSystemAudio else { throw TranscriptionError.noAudio }
        let engine = selectedEngine
        let language = selectedAppleLanguage

        var mic: [RawSegment] = []
        var system: [RawSegment] = []
        var speakerTurns: [SpeakerTurn]?
        var speakerError: String?
        if session.hasSystemAudio {
            let systemURL = folder.appendingPathComponent(RecordingSession.systemFileName)
            system = try await transcribeTrack(
                systemURL, label: "system audio", wordTimings: true,
                session: session, engine: engine, language: language
            )
            if !system.isEmpty {
                // A failed speaker split shouldn't lose the transcript; fall back to "Others".
                do {
                    speakerTurns = try await identifySpeakers(systemURL, session: session)
                } catch {
                    speakerError = error.localizedDescription
                }
            }
        }
        if session.hasMicrophone {
            mic = try await transcribeTrack(
                folder.appendingPathComponent(RecordingSession.micFileName),
                label: "your mic", wordTimings: false,
                session: session, engine: engine, language: language
            )
        }

        return Transcript(
            engine: engine,
            language: engine == .apple ? language.rawValue : nil,
            createdAt: .now,
            segments: TranscriptMerger.merge(mic: mic, system: system, speakerTurns: speakerTurns),
            speakerError: speakerError
        )
    }

    private func identifySpeakers(_ url: URL, session: RecordingSession) async throws -> [SpeakerTurn] {
        let label = "speakers"
        statuses[session.id] = .working(track: label, progress: .identifyingSpeakers)
        return try await diarizer.diarize(fileURL: url, onProgress: progressHandler(for: session.id, label: label))
    }

    private func transcribeTrack(
        _ url: URL,
        label: String,
        wordTimings: Bool,
        session: RecordingSession,
        engine: TranscriptionEngineKind,
        language: AppleSpeechLanguage
    ) async throws -> [RawSegment] {
        statuses[session.id] = .working(track: label, progress: .transcribing)
        let onProgress = progressHandler(for: session.id, label: label)
        switch engine {
        case .whisper:
            return try await whisper.transcribe(fileURL: url, wordTimings: wordTimings, onProgress: onProgress)
        case .apple:
            return try await apple.transcribe(fileURL: url, language: language, onProgress: onProgress)
        }
    }

    private func progressHandler(for id: UUID, label: String) -> @Sendable (TranscriptionProgress) -> Void {
        { progress in
            Task { @MainActor [weak self] in
                // Ignore updates that arrive after this step has finished.
                guard let self, case .working(let current, _) = self.statuses[id], current == label else { return }
                self.statuses[id] = .working(track: label, progress: progress)
            }
        }
    }

    private func save(_ transcript: Transcript, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(
            to: folder.appendingPathComponent(Transcript.fileName),
            options: .atomic
        )
    }
}
