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
        // Transcribe automatically once a recording stops, so it's ready when the user checks back.
        store.onSessionFinished = { [store, transcription] session in
            transcription.enqueue(session, folder: store.folderURL(for: session))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Finalize the audio files so a quit mid-recording keeps what was captured.
        store.stop()
    }
}
