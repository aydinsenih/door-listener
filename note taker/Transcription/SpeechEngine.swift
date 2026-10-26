//
//  SpeechEngine.swift
//  note taker
//

import Foundation

/// A speech-to-text model. The rest of the app only talks to this, so another model
/// can be swapped in without touching recording, VAD or the transcript.
protocol SpeechEngine: Actor {
    /// Downloads and loads the model if it isn't ready yet.
    func prepare(onProgress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws

    /// Starts transcribing one track. `wordTimings` asks for per-word times where the
    /// model has them, used to split lines between speakers.
    nonisolated func makeStream(wordTimings: Bool) -> any SpeechStream
}

/// Transcribes one track's utterances. They arrive in order, so a model that streams
/// natively can keep its decoder state from one utterance to the next.
protocol SpeechStream: Sendable {
    /// Returns the lines for one utterance, timed from the start of the track.
    func transcribe(_ utterance: Utterance) async throws -> [RawSegment]
}
