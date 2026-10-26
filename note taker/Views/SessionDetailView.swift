//
//  SessionDetailView.swift
//  note taker
//

import AppKit
import SwiftUI

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
                    Text("Transcribed with \(transcript.engine == .whisper ? "Whisper" : "Apple Speech")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let transcript {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript.plainText, forType: .string)
                }
            }
            Button(transcript == nil ? "Transcribe" : "Transcribe Again", systemImage: "text.bubble") {
                transcription.enqueue(session, folder: store.folderURL(for: session))
            }
            .disabled(transcription.isBusy(session) || session.endedAt == nil)
        }
        .padding()
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
            List(transcript.segments) { segment in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Transcript.timestamp(segment.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(segment.speaker)
                            .font(.caption.bold())
                            .foregroundStyle(segment.speaker == TranscriptMerger.meLabel ? Color.accentColor : .secondary)
                        Text(segment.text)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            }
        }
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
