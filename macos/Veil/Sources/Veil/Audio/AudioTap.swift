//  Far-end audio capture on macOS 14.4+ via Core Audio process taps.
//
//  This is the good path. It needs the "Audio Capture" TCC permission, NOT
//  Screen Recording, which is the loud one that lights a purple indicator in
//  the menu bar. It also taps by PID, so we capture Zoom and only Zoom: not
//  your music, and crucially not our own text-to-speech, which would otherwise
//  feed the transcript back into itself.

import AVFoundation
import AppKit
import CoreAudio
import Foundation

enum AudioTapError: Error, CustomStringConvertible {
    case unavailable
    case osStatus(String, OSStatus)
    case noProcesses

    var description: String {
        switch self {
        case .unavailable: return "Core Audio process taps need macOS 14.4 or later"
        case .noProcesses: return "none of the requested processes are producing audio"
        case .osStatus(let call, let s):
            return "\(call) failed: OSStatus \(s) (\(fourCC(s)))"
        }
    }
}

/// Core Audio reports errors as packed four-character codes more often than not.
func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
                 UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    let s = String(bytes: bytes, encoding: .ascii) ?? ""
    return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " } ? s : "\(status)"
}

@available(macOS 14.4, *)
final class ProcessAudioTap {

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "veil.audiotap", qos: .userInitiated)

    /// Called on `queue` with interleaved float samples and the stream format.
    var onSamples: (([Float], AudioStreamBasicDescription) -> Void)?

    private(set) var format = AudioStreamBasicDescription()

    // MARK: lifecycle

    /// - Parameter pids: processes to tap. Empty means everything except us,
    ///   which is the sane default for a call: whoever is talking, we want it,
    ///   but never our own output.
    func start(pids: [pid_t]) throws {
        let processObjects = try pids.compactMap { try Self.processObject(for: $0) }

        let description: CATapDescription
        if processObjects.isEmpty {
            // Global mixdown minus ourselves. Prevents TTS feedback loops.
            let selfObject = (try? Self.processObject(for: ProcessInfo.processInfo.processIdentifier))
                .flatMap { $0 }
            // The SDK bridges these as [AudioObjectID], not [NSNumber].
            let excluded: [AudioObjectID] = selfObject.map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        }
        description.name = "veil-far-end"
        description.uuid = UUID()

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw AudioTapError.osStatus("AudioHardwareCreateProcessTap", status) }

        let tapUID = try Self.stringProperty(kAudioTapPropertyUID, on: tapID)
        format = try Self.formatProperty(on: tapID)

        let outputUID = try Self.defaultOutputDeviceUID()

        // A private aggregate device is the only way to actually read a tap.
        let aggUID = UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "veil-aggregate",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID)
        guard status == noErr else { throw AudioTapError.osStatus("AudioHardwareCreateAggregateDevice", status) }

        let fmt = format
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let handler = self.onSamples else { return }
            let list = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard let first = list.first, let mData = first.mData else { return }
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { return }
            let samples = Array(UnsafeBufferPointer(
                start: mData.assumingMemoryBound(to: Float.self), count: count))
            handler(samples, fmt)
        }
        guard status == noErr else { throw AudioTapError.osStatus("AudioDeviceCreateIOProcIDWithBlock", status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw AudioTapError.osStatus("AudioDeviceStart", status) }
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }

    // MARK: property plumbing

    static func processObject(for pid: pid_t) throws -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var inputPID = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &inputPID, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    static func stringProperty(_ selector: AudioObjectPropertySelector,
                               on object: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioTapError.osStatus("get string property", status) }
        return value as String
    }

    static func formatProperty(on object: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw AudioTapError.osStatus("kAudioTapPropertyFormat", status) }
        return asbd
    }

    static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != 0 else {
            throw AudioTapError.osStatus("kAudioHardwarePropertyDefaultOutputDevice", status)
        }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr else { throw AudioTapError.osStatus("kAudioDevicePropertyDeviceUID", status) }
        return uid as String
    }

    /// PIDs of the usual conferencing suspects, for targeted tapping.
    static func conferencingPIDs() -> [pid_t] {
        let names = ["zoom.us", "Microsoft Teams", "Google Chrome", "Slack",
                     "Webex", "Discord", "FaceTime", "Safari", "Arc"]
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let name = app.localizedName, names.contains(name) else { return nil }
            return app.processIdentifier
        }
    }
}
