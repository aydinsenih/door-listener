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
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.radioGroup)

            if engine == .apple {
                Picker("Language", selection: $appleLanguage) {
                    ForEach(AppleSpeechLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Text("Apple Speech transcribes one language per recording. Use Whisper for conversations that mix Turkish and English. Lines appear live while recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Lines appear live while recording; silence is skipped by voice detection before it reaches Whisper. The Whisper model (about 1.6 GB) is downloaded the first time. Everything runs on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
