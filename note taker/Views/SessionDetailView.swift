//
//  SessionDetailView.swift
//  note taker
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shows a session's transcript, or its transcription progress.
struct SessionDetailView: View {
    @Environment(RecordingStore.self) private var store
    @Environment(TranscriptionService.self) private var transcription
    let session: RecordingSession

    private var transcript: Transcript? { transcription.transcripts[session.id] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: session.id) {
            transcription.loadTranscript(for: session, in: store.folderURL(for: session))
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.startedAt.formatted(date: .complete, time: .shortened))
                    .font(.headline)
                if let transcript {
                    Text(summary(of: transcript))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let speakerError = transcript.speakerError {
                        Text("Couldn't tell the other speakers apart: \(speakerError)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if let transcript {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript.plainText, forType: .string)
                }
                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button("Text (.txt)") { export(transcript, markdown: false) }
                    Button("Markdown (.md)") { export(transcript, markdown: true) }
                }
                .fixedSize()
            }
            Button(transcript == nil ? "Transcribe" : "Transcribe Again", systemImage: "text.bubble") {
                transcription.enqueue(session, folder: store.folderURL(for: session))
            }
            .disabled(transcription.isBusy(session) || session.endedAt == nil)
        }
        .padding()
    }

    private var title: String {
        "Recording, \(session.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func summary(of transcript: Transcript) -> String {
        let engine = transcript.engine == .whisper ? "Whisper" : "Apple Speech"
        let others = transcript.speakers.filter { $0 != TranscriptMerger.meLabel }.count
        guard transcript.speakerError == nil, others > 0 else { return "Transcribed with \(engine)" }
        return "Transcribed with \(engine) · \(others) other \(others == 1 ? "speaker" : "speakers")"
    }

    private func export(_ transcript: Transcript, markdown: Bool) {
        let fileExtension = markdown ? "md" : "txt"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Transcript \(session.folderName).\(fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = markdown ? transcript.markdown(title: title) : transcript.plainText
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch transcription.statuses[session.id] {
        case .queued:
            ProgressView("Waiting to transcribe…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .working(track, progress):
            TranscriptionProgressView(track: track, progress: progress)
        case let .failed(message):
            ContentUnavailableView(
                "Transcription failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case nil:
            if let transcript {
                TranscriptView(transcript: transcript)
            } else {
                ContentUnavailableView(
                    "No transcript yet",
                    systemImage: "text.bubble",
                    description: Text("Press Transcribe to create one on this Mac.")
                )
            }
        }
    }
}

private struct TranscriptionProgressView: View {
    let track: String
    let progress: TranscriptionProgress

    var body: some View {
        VStack(spacing: 12) {
            switch progress {
            case let .downloadingModel(fraction):
                ProgressView(value: fraction) {
                    Text("Downloading the speech model (first time only)…")
                }
                .frame(maxWidth: 320)
            case .loadingModel:
                ProgressView("Loading the speech model…")
                ElapsedSinceAppear()
            case .transcribing:
                ProgressView("Transcribing \(track)…")
            case .loadingSpeakerModel:
                ProgressView("Loading the speaker model…")
                ElapsedSinceAppear()
            case .identifyingSpeakers:
                ProgressView("Telling speakers apart…")
                ElapsedSinceAppear()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TranscriptView: View {
    let transcript: Transcript

    var body: some View {
        if transcript.segments.isEmpty {
            ContentUnavailableView(
                "No speech found",
                systemImage: "waveform.slash",
                description: Text("Nothing was recognized in this recording.")
            )
        } else {
            List(transcript.turns) { turn in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Transcript.timestamp(turn.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(turn.speaker)
                            .font(.caption.bold())
                            .foregroundStyle(color(for: turn.speaker))
                        Text(turn.text)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private static let speakerColors: [Color] = [.orange, .green, .purple, .pink, .teal, .brown]

    /// Me in the accent color, and a steady color per other speaker.
    private func color(for speaker: String) -> Color {
        if speaker == TranscriptMerger.meLabel { return .accentColor }
        let others = transcript.speakers.filter { $0 != TranscriptMerger.meLabel }
        guard speaker != TranscriptMerger.othersLabel, let index = others.firstIndex(of: speaker) else {
            return .secondary
        }
        return Self.speakerColors[index % Self.speakerColors.count]
    }
}

/// Shows how long a step has been running, so a slow step doesn't look frozen.
private struct ElapsedSinceAppear: View {
    @State private var start = Date.now

    var body: some View {
        ElapsedTimeText(since: start)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}
