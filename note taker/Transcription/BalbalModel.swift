//
//  BalbalModel.swift
//  note taker
//

import Foundation
import OnnxRuntimeBindings

/// balbal-v1, a small Turkish Conformer-CTC model (45M parameters), run with ONNX Runtime.
/// The ONNX graph takes 16 kHz audio and returns CTC log-probabilities per 40 ms frame.
/// It's decoded greedily here: the published KenLM beam search is Python and C++ only.
nonisolated final class BalbalModel {
    static let repository = "https://huggingface.co/erayyapagci/balbal-v1/resolve/main/"
    static let files = ["onnx/model-int8.onnx", "tokenizer/tokenizer.vocab"]

    /// One CTC frame: 10 ms hop with 4x subsampling.
    private static let frameDuration: TimeInterval = 0.04
    private static let classCount = 1025
    private static let blank = 1024
    /// The convolutional front end needs at least 0.25 s.
    private static let minimumSamples = 4000

    nonisolated struct Result {
        var text: String
        var words: [RawWord]
        /// Geometric mean probability of the emitted tokens, 0 to 1, the way Parakeet scores itself.
        var confidence: Float
    }

    private let env: ORTEnv
    private let session: ORTSession
    private let outputName: String
    private let pieces: [String]

    /// Loads a folder that holds `files`. Use `download(to:onProgress:)` first.
    init(folder: URL) throws {
        let vocab = try String(contentsOf: folder.appendingPathComponent("tokenizer/tokenizer.vocab"), encoding: .utf8)
        pieces = vocab.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.split(separator: "\t", maxSplits: 1).first ?? "") }
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(4)
        try options.setGraphOptimizationLevel(.all)
        session = try ORTSession(
            env: env,
            modelPath: folder.appendingPathComponent("onnx/model-int8.onnx").path,
            sessionOptions: options
        )
        guard let name = try session.outputNames().first else { throw TranscriptionError.modelUnavailable }
        outputName = name
    }

    static func isDownloaded(in folder: URL) -> Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    static func download(to folder: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        for (index, file) in files.enumerated() {
            let destination = folder.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            onProgress(Double(index) / Double(files.count))
            guard let url = URL(string: repository + file) else { throw TranscriptionError.modelUnavailable }
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TranscriptionError.modelUnavailable }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        onProgress(1)
    }

    /// Transcribes up to 30 s of 16 kHz mono audio. Word times are from the start of `samples`.
    func transcribe(_ samples: [Float]) throws -> Result {
        var audio = samples
        if audio.count < Self.minimumSamples {
            audio += [Float](repeating: 0, count: Self.minimumSamples - audio.count)
        }
        let data = audio.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        let input = try ORTValue(tensorData: data, elementType: .float, shape: [1, NSNumber(value: audio.count)])
        let outputs = try session.run(
            withInputs: ["audio": input],
            outputNames: [outputName],
            runOptions: nil
        )
        guard let output = outputs[outputName] else { throw TranscriptionError.modelUnavailable }
        let logProbs = try output.tensorData() as Data
        return logProbs.withUnsafeBytes { raw in
            decode(Array(raw.bindMemory(to: Float.self)))
        }
    }

    /// Greedy CTC: the best class per frame, repeats merged, blanks dropped.
    private func decode(_ logProbs: [Float]) -> Result {
        let frames = logProbs.count / Self.classCount
        var tokens: [(id: Int, frame: Int, logProbability: Float)] = []
        var previous = Self.blank
        for frame in 0..<frames {
            let row = logProbs[(frame * Self.classCount)..<((frame + 1) * Self.classCount)]
            var best = row.startIndex
            for index in row.indices where row[index] > row[best] { best = index }
            let id = best - row.startIndex
            if id != Self.blank, id != previous {
                tokens.append((id, frame, row[best]))
            }
            previous = id
        }

        var words: [RawWord] = []
        for token in tokens {
            guard token.id < pieces.count else { continue }
            let piece = pieces[token.id]
            if piece.hasPrefix("<"), piece.hasSuffix(">") { continue }
            let start = Double(token.frame) * Self.frameDuration
            let end = start + Self.frameDuration
            let startsWord = piece.hasPrefix("▁") || words.isEmpty
            let text = piece.replacingOccurrences(of: "▁", with: " ")
            if startsWord {
                words.append(RawWord(start: start, end: end, text: text))
            } else {
                words[words.count - 1].text += text
                words[words.count - 1].end = end
            }
        }
        let confidence = tokens.isEmpty ? 0 : exp(tokens.map(\.logProbability).reduce(0, +) / Float(tokens.count))
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        return Result(text: text, words: words, confidence: confidence)
    }
}
