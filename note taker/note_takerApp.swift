//
//  note_takerApp.swift
//  note taker
//
//  Created by Senih Aydin on 10/25/26.
//

import SwiftUI

@main
struct note_takerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Door Listener", id: "main") {
            ContentView()
                .environment(appDelegate.store)
                .environment(appDelegate.playback)
                .environment(appDelegate.transcription)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(appDelegate.store)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.store)
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = RecordingStore()
    let playback = PlaybackController()
    let transcription = TranscriptionService()

    override init() {
        super.init()
        // Transcribe while recording, so lines show up as people talk.
        store.startLiveTranscription = { [transcription] session, folder in
            transcription.startLive(session, folder: folder)
        }
        // If live transcription couldn't start, transcribe once the recording stops instead.
        store.onSessionFinished = { [store, transcription] session in
            guard !transcription.isLive(session) else { return }
            transcription.enqueue(session, folder: store.folderURL(for: session))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Finalize the audio files so a quit mid-recording keeps what was captured.
        store.stop()
    }
}
