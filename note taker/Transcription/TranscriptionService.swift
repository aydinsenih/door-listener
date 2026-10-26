//
//  TranscriptionService.swift
//  note taker
//

import Foundation
import Observation
import WhisperKit

nonisolated enum TranscriptionProgress: Sendable, Equatable {
    case downloadingModel(Double)
    case loadingModel
    case transcribing
    case loadingSpeakerModel
    case identifyingSpeakers
}

nonisolated enum AudioTrack: Sendable {
    case microphone
    case systemAudio
}

/// The audio inputs of a recording that's transcribed while it records.
nonisolated final class LiveTranscription: Sendable {
    let microphone: LiveTrackProcessor?
    let systemAudio: LiveTrackProcessor?
    fileprivate let events: AsyncStream<LiveEvent>.Continuation

    fileprivate init(
        microphone: LiveTrackProcessor?,
        systemAudio: LiveTrackProcessor?,
        events: AsyncStream<LiveEvent>.Continuation
    ) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.events = events
    }

    /// Hands over what was still being said, then finalizes the transcript.
    /// Call after the recorders have stopped.
    func finish(_ session: RecordingSession) {
        microphone?.finish()
        systemAudio?.finish()
        events.yield(.stopped(session))
        events.finish()
    }
}

fileprivate nonisolated enum LiveEvent: Sendable {
    case utterance(AudioTrack, Utterance)
    case stopped(RecordingSession)
}

/// Transcribes recordings live while they record, and saved recordings on request.
/// Keeps their transcripts.
@Observable
final class TranscriptionService {
    enum Status: Equatable {
        case queued
        case working(track: String, progress: TranscriptionProgress)
        case failed(String)
    }

    /// A recording that's transcribed as it records.
    struct LiveStatus: Equatable {
        /// Set while the model loads, and while speakers are identified after stopping.
        var progress: TranscriptionProgress?
        /// Utterances heard but not transcribed yet.
        var backlog = 0
        var error: String?
    }

    private(set) var statuses: [UUID: Status] = [:]
    private(set) var liveStatuses: [UUID: LiveStatus] = [:]
    private(set) var transcripts: [UUID: Transcript] = [:]

    @ObservationIgnored private let whisper: WhisperEngine
    @ObservationIgnored private let diarizer: SpeakerDiarizer
    @ObservationIgnored private var appleEngines: [AppleSpeechLanguage: AppleSpeechEngine] = [:]
    @ObservationIgnored private var liveSessions: [UUID: LiveSession] = [:]
    @ObservationIgnored private var jobs: [Job] = []
    @ObservationIgnored private var isRunning = false

    /// Work runs one job at a time, in order, so the model is never asked for two things at once.
    private enum Job {
        case prepareLive(UUID)
        case utterance(UUID, AudioTrack, Utterance)
        case finishLive(RecordingSession)
        case file(RecordingSession, URL)
    }

    /// What's collected for a recording while it records.
    private struct LiveSession {
        let engine: any SpeechEngine
        let engineKind: TranscriptionEngineKind
        let language: AppleSpeechLanguage
        let folder: URL
        let microphoneStream: any SpeechStream
        let systemStream: any SpeechStream
        var mic: [RawSegment] = []
        var system: [RawSegment] = []
    }

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

    func isLive(_ session: RecordingSession) -> Bool {
        liveStatuses[session.id] != nil
    }

    func isBusy(_ session: RecordingSession) -> Bool {
        if isLive(session) { return true }
        switch statuses[session.id] {
        case .queued, .working: return true
        default: return false
        }
    }

    // MARK: - Live

    /// Starts transcribing a recording as it records. Returns nil if voice detection can't
    /// run, in which case the recording is transcribed after it stops.
    func startLive(_ session: RecordingSession, folder: URL) -> LiveTranscription? {
        let (events, continuation) = AsyncStream<LiveEvent>.makeStream()
        let microphone: LiveTrackProcessor
        let systemAudio: LiveTrackProcessor
        do {
            microphone = try LiveTrackProcessor(label: "mic") { continuation.yield(.utterance(.microphone, $0)) }
            systemAudio = try LiveTrackProcessor(label: "system") { continuation.yield(.utterance(.systemAudio, $0)) }
        } catch {
            return nil
        }

        let kind = selectedEngine
        let language = selectedAppleLanguage
        let engine = speechEngine(for: kind, language: language)
        let id = session.id
        liveSessions[id] = LiveSession(
            engine: engine,
            engineKind: kind,
            language: language,
            folder: folder,
            microphoneStream: engine.makeStream(wordTimings: false),
            systemStream: engine.makeStream(wordTimings: true)
        )
        liveStatuses[id] = LiveStatus()
        transcripts[id] = Transcript(engine: kind, language: kind == .apple ? language.rawValue : nil, createdAt: .now, segments: [])

        // Load the model now, so it's ready by the time someone finishes their first sentence.
        enqueue(.prepareLive(id))
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case let .utterance(track, utterance):
                    liveStatuses[id]?.backlog += 1
                    enqueue(.utterance(id, track, utterance))
                case let .stopped(session):
                    enqueue(.finishLive(session))
                }
            }
        }
        return LiveTranscription(microphone: microphone, systemAudio: systemAudio, events: continuation)
    }

    private func prepareLive(_ id: UUID) async {
        guard let live = liveSessions[id] else { return }
        do {
            try await live.engine.prepare(onProgress: liveProgressHandler(for: id))
            liveStatuses[id]?.progress = nil
        } catch {
            liveStatuses[id]?.progress = nil
            liveStatuses[id]?.error = error.localizedDescription
        }
    }

    private func transcribeLive(_ utterance: Utterance, track: AudioTrack, session id: UUID) async {
        defer { liveStatuses[id]?.backlog -= 1 }
        // After a failure the saved audio is transcribed once recording stops instead.
        guard let live = liveSessions[id], liveStatuses[id]?.error == nil else { return }
        do {
            switch track {
            case .microphone:
                let segments = try await live.microphoneStream.transcribe(utterance)
                liveSessions[id]?.mic.append(contentsOf: segments)
            case .systemAudio:
                let segments = try await live.systemStream.transcribe(utterance)
                liveSessions[id]?.system.append(contentsOf: segments)
            }
        } catch {
            liveStatuses[id]?.error = error.localizedDescription
            return
        }
        guard let live = liveSessions[id] else { return }
        let transcript = makeTranscript(engine: live.engineKind, language: live.language, mic: live.mic, system: live.system)
        transcripts[id] = transcript
        // Saved as it grows, so a crash or a force quit keeps what was said.
        try? save(transcript, in: live.folder)
    }

    /// Runs after the last utterance: splits the other side into speakers and saves.
    private func finishLive(_ session: RecordingSession) async {
        let id = session.id
        guard let live = liveSessions[id] else { return }
        guard session.hasMicrophone || session.hasSystemAudio else {
            // Recording never started; there's nothing to keep.
            liveSessions[id] = nil
            liveStatuses[id] = nil
            transcripts[id] = nil
            return
        }
        let failed = liveStatuses[id]?.error != nil

        var speakerTurns: [SpeakerTurn]?
        var speakerError: String?
        if !failed, session.hasSystemAudio, !live.system.isEmpty {
            do {
                speakerTurns = try await diarizer.diarize(
                    fileURL: live.folder.appendingPathComponent(RecordingSession.systemFileName),
                    onProgress: liveProgressHandler(for: id)
                )
            } catch {
                speakerError = error.localizedDescription
            }
        }

        liveSessions[id] = nil
        liveStatuses[id] = nil
        if failed {
            // Something went wrong live (for example the model couldn't download), so
            // transcribe the saved audio instead.
            statuses[id] = .queued
            await transcribeFile(session, folder: live.folder)
            return
        }

        let transcript = makeTranscript(
            engine: live.engineKind, language: live.language,
            mic: live.mic, system: live.system,
            speakerTurns: speakerTurns, speakerError: speakerError
        )
        transcripts[id] = transcript
        do {
            try save(transcript, in: live.folder)
        } catch {
            statuses[id] = .failed(error.localizedDescription)
        }
    }

    private func liveProgressHandler(for id: UUID) -> @Sendable (TranscriptionProgress) -> Void {
        { progress in
            Task { @MainActor [weak self] in
                self?.liveStatuses[id]?.progress = progress
            }
        }
    }

    // MARK: - Saved recordings

    /// Transcribes a saved recording again, for example with another engine.
    func enqueue(_ session: RecordingSession, folder: URL) {
        guard !isBusy(session) else { return }
        statuses[session.id] = .queued
        enqueue(.file(session, folder))
    }

    private func transcribeFile(_ session: RecordingSession, folder: URL) async {
        do {
            let transcript = try await transcribe(session, folder: folder)
            try save(transcript, in: folder)
            transcripts[session.id] = transcript
            statuses[session.id] = nil
        } catch {
            statuses[session.id] = .failed(error.localizedDescription)
        }
    }

    private func transcribe(_ session: RecordingSession, folder: URL) async throws -> Transcript {
        guard session.hasMicrophone || session.hasSystemAudio else { throw TranscriptionError.noAudio }
        let kind = selectedEngine
        let language = selectedAppleLanguage
        let engine = speechEngine(for: kind, language: language)

        statuses[session.id] = .working(track: "model", progress: .loadingModel)
        try await engine.prepare(onProgress: progressHandler(for: session.id, label: "model"))

        var mic: [RawSegment] = []
        var system: [RawSegment] = []
        var speakerTurns: [SpeakerTurn]?
        var speakerError: String?
        if session.hasSystemAudio {
            let systemURL = folder.appendingPathComponent(RecordingSession.systemFileName)
            system = try await transcribeTrack(
                systemURL, label: "system audio", stream: engine.makeStream(wordTimings: true), session: session
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
                label: "your mic", stream: engine.makeStream(wordTimings: false), session: session
            )
        }

        return makeTranscript(
            engine: kind, language: language,
            mic: mic, system: system,
            speakerTurns: speakerTurns, speakerError: speakerError
        )
    }

    private func identifySpeakers(_ url: URL, session: RecordingSession) async throws -> [SpeakerTurn] {
        let label = "speakers"
        statuses[session.id] = .working(track: label, progress: .identifyingSpeakers)
        return try await diarizer.diarize(fileURL: url, onProgress: progressHandler(for: session.id, label: label))
    }

    /// Runs the same VAD as live recording over a saved track, then transcribes each utterance.
    private func transcribeTrack(
        _ url: URL,
        label: String,
        stream: any SpeechStream,
        session: RecordingSession
    ) async throws -> [RawSegment] {
        statuses[session.id] = .working(track: label, progress: .transcribing)
        let utterances = try await Task.detached(priority: .userInitiated) {
            try SpeechSegmenter.utterances(
                in: AudioProcessor.loadAudioAsFloatArray(fromPath: url.path),
                vad: SileroVAD()
            )
        }.value

        var segments: [RawSegment] = []
        for utterance in utterances {
            segments += try await stream.transcribe(utterance)
        }
        return segments
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

    // MARK: - Shared

    private func enqueue(_ job: Job) {
        jobs.append(job)
        if !isRunning {
            Task { await runJobs() }
        }
    }

    private func runJobs() async {
        isRunning = true
        defer { isRunning = false }
        while !jobs.isEmpty {
            switch jobs.removeFirst() {
            case let .prepareLive(id):
                await prepareLive(id)
            case let .utterance(id, track, utterance):
                await transcribeLive(utterance, track: track, session: id)
            case let .finishLive(session):
                await finishLive(session)
            case let .file(session, folder):
                await transcribeFile(session, folder: folder)
            }
        }
    }

    private func speechEngine(for kind: TranscriptionEngineKind, language: AppleSpeechLanguage) -> any SpeechEngine {
        switch kind {
        case .whisper:
            return whisper
        case .apple:
            if let engine = appleEngines[language] { return engine }
            let engine = AppleSpeechEngine(language: language)
            appleEngines[language] = engine
            return engine
        }
    }

    private func makeTranscript(
        engine: TranscriptionEngineKind,
        language: AppleSpeechLanguage,
        mic: [RawSegment],
        system: [RawSegment],
        speakerTurns: [SpeakerTurn]? = nil,
        speakerError: String? = nil
    ) -> Transcript {
        Transcript(
            engine: engine,
            language: engine == .apple ? language.rawValue : nil,
            createdAt: .now,
            segments: TranscriptMerger.merge(mic: mic, system: system, speakerTurns: speakerTurns),
            speakerError: speakerError
        )
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
