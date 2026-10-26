//
//  MenuBarContent.swift
//  note taker
//

import SwiftUI

/// Menu bar controls, so recording can run while the main window is closed.
struct MenuBarContent: View {
    @Environment(RecordingStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(store.isRecording ? "Stop Listening" : "Start Listening") {
            store.toggle()
        }
        .disabled(store.isStarting)

        if let session = store.activeSession {
            Text("Recording since \(session.startedAt.formatted(date: .omitted, time: .shortened))")
        }

        Divider()

        Button("Open Door Listener") {
            openWindow(id: "main")
            NSApp.activate()
        }

        Divider()

        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

struct MenuBarLabel: View {
    @Environment(RecordingStore.self) private var store

    var body: some View {
        Image(systemName: store.isRecording ? "record.circle.fill" : "waveform")
    }
}
