//
//  RecorderHeader.swift
//  note taker
//

import SwiftUI

/// The Start/Stop control with a running timer while recording.
struct RecorderHeader: View {
    @Environment(RecordingStore.self) private var store
    @AppStorage(RecordingStore.echoCancellationKey) private var echoCancellation = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls
            Toggle("Remove speaker sound from mic (echo cancellation)", isOn: $echoCancellation)
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(store.isRecording)
                .help("Turn off if you use headphones or your voice sounds muffled.")
        }
        .padding()
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                store.toggle()
            } label: {
                Label(
                    store.isRecording ? "Stop" : "Start Listening",
                    systemImage: store.isRecording ? "stop.fill" : "record.circle"
                )
                .frame(minWidth: 140)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(store.isRecording ? .red : .accentColor)
            .disabled(store.isStarting)

            if let session = store.activeSession {
                VStack(alignment: .leading, spacing: 2) {
                    ElapsedTimeText(since: session.startedAt)
                        .font(.title3.monospacedDigit())
                    Text(sourcesDescription(for: session))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Records your mic and everything your Mac plays.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func sourcesDescription(for session: RecordingSession) -> String {
        switch (session.hasMicrophone, session.hasSystemAudio) {
        case (true, true): "Recording mic and system audio"
        case (true, false): "Recording mic only"
        case (false, true): "Recording system audio only"
        case (false, false): "Not recording"
        }
    }
}

struct ElapsedTimeText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(formatDuration(context.date.timeIntervalSince(since)))
        }
    }
}

func formatDuration(_ interval: TimeInterval) -> String {
    Duration.seconds(max(0, interval)).formatted(.time(pattern: .hourMinuteSecond))
}
