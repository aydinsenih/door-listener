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
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(appDelegate.store)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = RecordingStore()

    func applicationWillTerminate(_ notification: Notification) {
        // Finalize the audio files so a quit mid-recording keeps what was captured.
        store.stop()
    }
}
