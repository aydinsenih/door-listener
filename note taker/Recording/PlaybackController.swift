//
//  PlaybackController.swift
//  note taker
//

import AVFoundation
import Observation

/// Plays back a session's tracks, either one alone or both in sync.
@Observable
final class PlaybackController: NSObject, AVAudioPlayerDelegate {
    enum Track: Hashable {
        case microphone
        case systemAudio
        case both
    }

    private(set) var sessionID: UUID?
    private(set) var track: Track?
    var errorMessage: String?

    @ObservationIgnored private var players: [AVAudioPlayer] = []

    var currentTime: TimeInterval { players.first?.currentTime ?? 0 }
    var duration: TimeInterval { players.map(\.duration).max() ?? 0 }

    func isPlaying(_ session: RecordingSession) -> Bool {
        sessionID == session.id
    }

    func play(_ session: RecordingSession, track: Track, in folder: URL) {
        stop()

        var urls: [URL] = []
        if track != .systemAudio, session.hasMicrophone {
            urls.append(folder.appendingPathComponent(RecordingSession.micFileName))
        }
        if track != .microphone, session.hasSystemAudio {
            urls.append(folder.appendingPathComponent(RecordingSession.systemFileName))
        }

        do {
            players = try urls.map { url in
                let player = try AVAudioPlayer(contentsOf: url)
                player.delegate = self
                player.prepareToPlay()
                return player
            }
        } catch {
            players = []
            errorMessage = "Couldn't play this recording: \(error.localizedDescription)"
            return
        }
        guard let first = players.first else { return }

        // Start every track at the same device time so mic and system audio line up.
        let startTime = first.deviceCurrentTime + 0.1
        players.forEach { $0.play(atTime: startTime) }
        sessionID = session.id
        self.track = track
    }

    func stop() {
        players.forEach { $0.stop() }
        players = []
        sessionID = nil
        track = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.players.allSatisfy({ !$0.isPlaying }) {
                self.stop()
            }
        }
    }
}
