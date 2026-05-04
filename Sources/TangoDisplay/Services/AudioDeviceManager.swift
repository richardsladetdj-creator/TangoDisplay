import CoreAudio
import Foundation

struct AudioOutputDevice: Identifiable, Equatable {
    let id: String   // CoreAudio device UID (stable across reboots)
    let name: String
}

enum AudioDeviceManager {
    static func outputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        var result: [AudioOutputDevice] = []

        for deviceID in deviceIDs {
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            let hasOutput = AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr
                && streamsSize > 0
            guard hasOutput else { continue }

            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: Unmanaged<CFString>? = nil
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard withUnsafeMutablePointer(to: &uidRef, {
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, $0)
            }) == noErr, let uid = uidRef?.takeRetainedValue() else { continue }

            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: Unmanaged<CFString>? = nil
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard withUnsafeMutablePointer(to: &nameRef, {
                AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, $0)
            }) == noErr, let name = nameRef?.takeRetainedValue() else { continue }

            result.append(AudioOutputDevice(id: uid as String, name: name as String))
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Returns the numeric CoreAudio `AudioDeviceID` for the given UID string,
    /// needed to route `AVAudioEngine`'s output node to a specific device.
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for deviceID in deviceIDs {
            var uidRef: Unmanaged<CFString>? = nil
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard withUnsafeMutablePointer(to: &uidRef, {
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, $0)
            }) == noErr, let found = uidRef?.takeRetainedValue() else { continue }
            if (found as String) == uid { return deviceID }
        }
        return nil
    }
}
