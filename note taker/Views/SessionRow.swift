//
//  SessionRow.swift
//  note taker
//

import SwiftUI

struct SessionRow: View {
    @Environment(RecordingStore.self) private var store
    let session: RecordingSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Text(formatDuration(session.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.hasMicrophone {
                Image(systemName: "mic")
                    .help("Microphone recorded")
            }
            if session.hasSystemAudio {
                Image(systemName: "speaker.wave.2")
                    .help("System audio recorded")
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Show in Finder") { store.revealInFinder(session) }
            Divider()
            Button("Move to Trash", role: .destructive) { store.moveToTrash(session) }
        }
    }
}
