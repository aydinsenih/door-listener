//
//  SileroVAD.swift
//  note taker
//

import Foundation
import OnnxRuntimeBindings

/// Silero VAD v5 (bundled ONNX model, about 2 MB): the chance that 32 ms of 16 kHz audio
/// is speech. The model carries state from one window to the next, so use one instance
/// per track and feed it in order.
nonisolated final class SileroVAD {
    /// Samples per window at 16 kHz, as the model expects.
    static let windowSize = 512
    /// v5 also reads the last 64 samples of the previous window.
    private static let contextSize = 64
    private static let stateSize = 2 * 1 * 128

    private let env: ORTEnv
    private let session: ORTSession
    private var state = [Float](repeating: 0, count: stateSize)
    private var context = [Float](repeating: 0, count: contextSize)

    init() throws {
        guard let url = Bundle.main.url(forResource: "silero_vad", withExtension: "onnx") else {
            throw TranscriptionError.vadModelMissing
        }
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        session = try ORTSession(env: env, modelPath: url.path, sessionOptions: options)
    }

    /// Speech probability of one window of `windowSize` samples.
    func speechProbability(_ window: [Float]) throws -> Float {
        precondition(window.count == Self.windowSize)
        let input = context + window
        var sampleRate = Int64(SpeechSegmenter.sampleRate)
        let outputs = try session.run(
            withInputs: [
                "input": Self.tensor(input, shape: [1, input.count]),
                "state": Self.tensor(state, shape: [2, 1, 128]),
                "sr": ORTValue(
                    tensorData: NSMutableData(bytes: &sampleRate, length: MemoryLayout<Int64>.size),
                    elementType: .int64,
                    shape: []
                ),
            ],
            outputNames: ["output", "stateN"],
            runOptions: nil
        )
        guard let output = outputs["output"], let newState = outputs["stateN"] else {
            throw TranscriptionError.vadFailed
        }
        state = try Self.floats(in: newState)
        context = Array(input.suffix(Self.contextSize))
        return try Self.floats(in: output).first ?? 0
    }

    private static func tensor(_ values: [Float], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        return try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    }

    private static func floats(in value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

nonisolated extension SpeechSegmenter {
    /// Cuts a whole track (16 kHz mono) into utterances, for transcribing a saved file.
    static func utterances(in samples: [Float], vad: SileroVAD) throws -> [Utterance] {
        var segmenter = SpeechSegmenter()
        var utterances: [Utterance] = []
        var start = 0
        while start + SileroVAD.windowSize <= samples.count {
            let window = Array(samples[start..<(start + SileroVAD.windowSize)])
            if let utterance = segmenter.process(window, probability: try vad.speechProbability(window)) {
                utterances.append(utterance)
            }
            start += SileroVAD.windowSize
        }
        if let last = segmenter.finish() {
            utterances.append(last)
        }
        return utterances
    }
}
