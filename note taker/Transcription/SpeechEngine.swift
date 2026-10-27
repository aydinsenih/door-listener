//
//  SpeechEngine.swift
//  note taker
//

import Foundation

/// A speech-to-text model. The rest of the app only talks to this, so another model
/// can be swapped in without touching recording, VAD or the transcript.
nonisolated protocol SpeechEngine: Actor {
    /// Downloads and loads the model if it isn't ready yet.
    func prepare(onProgress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws

    /// Starts transcribing one track. `wordTimings` asks for per-word times where the
    /// model has them, used to split lines between speakers.
    nonisolated func makeStream(wordTimings: Bool) -> any SpeechStream
}

/// Transcribes one track's utterances, in order.
///
/// A model that streams natively sets `isStreaming`: it then also gets each utterance's
/// audio through `feed` while it's being said, and shows text before the speaker pauses.
nonisolated protocol SpeechStream: Sendable {
    var isStreaming: Bool { get }

    /// Speech of the utterance in progress, timed from the start of the track. Returns
    /// the text heard so far in this utterance.
    func feed(_ samples: [Float], at time: TimeInterval) async throws -> String

    /// The speech fed since the last utterance was a click or a cough; forget it.
    func discard() async

    /// Returns the lines for one finished utterance, timed from the start of the track.
    /// A streaming model has already been fed its audio, unless it's transcribing a file.
    func transcribe(_ utterance: Utterance) async throws -> [RawSegment]
}

nonisolated extension SpeechStream {
    var isStreaming: Bool { false }
    func feed(_ samples: [Float], at time: TimeInterval) async throws -> String { "" }
    func discard() async {}
}
