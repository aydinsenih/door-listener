//
//  ContentView.swift
//  note taker
//
//  Created by Senih Aydin on 10/25/26.
//

import SwiftUI

struct ContentView: View {
    @Environment(RecordingStore.self) private var store
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        VStack(spacing: 0) {
            RecorderHeader()
            Divider()
            if store.sessions.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "waveform",
                    description: Text("Press Start Listening to record your microphone and your Mac's audio.")
                )
            } else {
                List(store.sessions) { session in
                    SessionRow(session: session)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
        .alert(
            "Recording problem",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .alert(
            "Playback problem",
            isPresented: Binding(
                get: { playback.errorMessage != nil },
                set: { if !$0 { playback.errorMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(playback.errorMessage ?? "")
        }
    }
}

#Preview {
    ContentView()
        .environment(RecordingStore())
        .environment(PlaybackController())
}
