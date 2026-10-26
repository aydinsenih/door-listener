//
//  RecorderError.swift
//  note taker
//

import Foundation

nonisolated enum RecorderError: LocalizedError {
    case microphonePermissionDenied
    case noInputDevice
    case noOutputDevice
    case unsupportedSystemAudioFormat
    case coreAudio(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone."
        case .noInputDevice:
            "No microphone was found."
        case .noOutputDevice:
            "No audio output device was found."
        case .unsupportedSystemAudioFormat:
            "The system audio format is not supported."
        case let .coreAudio(operation, status):
            "\(operation) failed (error \(status)). Check System Settings > Privacy & Security > Screen & System Audio Recording."
        }
    }
}

nonisolated func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw RecorderError.coreAudio(operation: operation, status: status)
    }
}
