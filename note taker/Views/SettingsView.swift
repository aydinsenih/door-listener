//
//  SettingsView.swift
//  note taker
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(TranscriptionEngineKind.settingsKey)
    private var engine: TranscriptionEngineKind = .default
    @AppStorage(AppleSpeechLanguage.settingsKey)
    private var appleLanguage: AppleSpeechLanguage = .default

    var body: some View {
        Form {
            Picker("Transcription engine", selection: $engine) {
                ForEach(TranscriptionEngineKind.allCases) { kind in
                    VStack(alignment: .leading) {
                        Text(kind.displayName)
                        Text(kind.memoryEstimate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(kind)
                }
            }
            .pickerStyle(.radioGroup)

            switch engine {
            case .whisper:
                Text("A line appears a moment after each speaker pauses. Silence is skipped by voice detection before it reaches Whisper. The model (about 1.6 GB) is downloaded the first time. Everything runs on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .qwenSmall, .qwenLarge:
                Text("A line appears a moment after each speaker pauses, like Whisper. Qwen3-ASR detects the language per sentence. It gives no word timings, so a sentence where two people overlap goes to one speaker. The model (\(engine == .qwenSmall ? "about 0.65 GB" : "about 2.3 GB")) is downloaded the first time. Everything runs on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .bilingual:
                Text("Each sentence goes to balbal if it's Turkish or Nemotron 3.5, pinned to English, if it's English, picked by a small language detection model. Short or unclear sentences go through both, and the more confident result is kept. A sentence that switches language halfway goes to one model. The models (about 0.8 GB together) are downloaded the first time. Everything runs on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .balbal:
                Text("A small Turkish model that runs on the CPU. English comes out poorly, so use Whisper or Turkish + English for mixed conversations. The model (about 70 MB) is downloaded the first time. Free for personal and small-business use, see its license on Hugging Face.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .apple:
                Picker("Language", selection: $appleLanguage) {
                    ForEach(AppleSpeechLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Text("Apple Speech transcribes one language per recording. Use Whisper for conversations that mix Turkish and English.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Changes apply to the next recording. Transcribe Again uses the engine picked here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
