//
//  SystemAudioRecorder.swift
//  note taker
//

import AVFoundation
import AudioToolbox
import CoreAudio

/// Records everything the Mac plays (calls, browser, videos) using a Core Audio
/// process tap. macOS asks the user for "System Audio Recording" permission the
/// first time this starts.
nonisolated final class SystemAudioRecorder: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: AudioFileWriter?
    private let ioQueue = DispatchQueue(label: "SystemAudioRecorder.io", qos: .userInitiated)

    func start(writingTo url: URL) throws {
        do {
            try startTap(writingTo: url)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)

        writer?.close()
        writer = nil
    }

    private func startTap(writingTo url: URL) throws {
        // A global stereo tap of every process except this app, so the mic's voice
        // processing and in-app playback don't end up in the system track.
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(tapDescription, &tap), "Creating the system audio tap")
        tapID = tap

        // The tap is read through a private aggregate device that wraps the
        // current output device.
        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Door Listener System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ],
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
            "Creating the system audio device"
        )
        aggregateID = aggregate

        var streamDescription = try tapStreamDescription()
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw RecorderError.unsupportedSystemAudioFormat
        }
        let writer = try AudioFileWriter(url: url, format: format, label: "system")
        self.writer = writer

        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregate, ioQueue) { _, inputData, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: inputData,
                    deallocator: nil
                ) else { return }
                writer.append(buffer)
            },
            "Connecting to system audio"
        )
        try check(AudioDeviceStart(aggregate, ioProcID), "Starting system audio capture")
    }

    private func tapStreamDescription() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description),
            "Reading the system audio format"
        )
        return description
    }

    private static func ownProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &processObject
        )
        guard status == noErr, processObject != kAudioObjectUnknown else { return [] }
        return [processObject]
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
            "Finding the output device"
        )

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid),
            "Reading the output device"
        )
        guard let uid else { throw RecorderError.noOutputDevice }
        return uid.takeRetainedValue() as String
    }
}
