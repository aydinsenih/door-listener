//
//  SessionRow.swift
//  note taker
//

import SwiftUI

struct SessionRow: View {
    @Environment(RecordingStore.self) private var store
    @Environment(PlaybackController.self) private var playback
    @Environment(TranscriptionService.self) private var transcription
    let session: RecordingSession

    private var isPlaying: Bool { playback.isPlaying(session) }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if isPlaying {
                    playback.stop()
                } else {
                    play(.both)
                }
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .help(isPlaying ? "Stop" : "Play mic and system audio together")

            VStack(alignment: .leading, spacing: 2) {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                if isPlaying {
                    PlaybackProgressText()
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(formatDuration(session.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if transcription.isBusy(session) {
                ProgressView()
                    .controlSize(.small)
                    .help("Transcribing")
            }
            if session.hasMicrophone {
                trackButton(.microphone, systemImage: "mic", help: "Play mic only")
            }
            if session.hasSystemAudio {
                trackButton(.systemAudio, systemImage: "speaker.wave.2", help: "Play system audio only")
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Play Mic Only") { play(.microphone) }
                .disabled(!session.hasMicrophone)
            Button("Play System Audio Only") { play(.systemAudio) }
                .disabled(!session.hasSystemAudio)
            Divider()
            Button("Show in Finder") { store.revealInFinder(session) }
            Divider()
            Button("Move to Trash", role: .destructive) {
                if isPlaying { playback.stop() }
                store.moveToTrash(session)
            }
        }
    }

    private func trackButton(_ track: PlaybackController.Track, systemImage: String, help: String) -> some View {
        let active = isPlaying && playback.track == track
        return Button {
            if active {
                playback.stop()
            } else {
                play(track)
            }
        } label: {
            Image(systemName: active ? "\(systemImage).fill" : systemImage)
                .foregroundStyle(active ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func play(_ track: PlaybackController.Track) {
        playback.play(session, track: track, in: store.folderURL(for: session))
    }
}

private struct PlaybackProgressText: View {
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text("\(formatDuration(playback.currentTime)) / \(formatDuration(playback.duration))")
        }
    }
}
