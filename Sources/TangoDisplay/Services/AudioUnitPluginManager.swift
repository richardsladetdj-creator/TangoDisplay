import AVFoundation
import OSLog
import TangoDisplayCore

enum AudioUnitPluginError: Error, LocalizedError {
    case componentNotFound
    case instantiationFailed(String)
    case graphConnectionFailed(String)
    case uiUnavailable

    var errorDescription: String? {
        switch self {
        case .componentNotFound:           return "Audio Unit component not found on this Mac."
        case .instantiationFailed(let r):  return "Audio Unit instantiation failed: \(r)"
        case .graphConnectionFailed(let r): return "Audio graph connection failed: \(r)"
        case .uiUnavailable:               return "This plugin does not provide an editor UI."
        }
    }
}

final class AudioUnitPluginManager {

    func availableEffects() -> [AudioUnitPluginSelection] {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return AVAudioUnitComponentManager.shared()
            .components(matching: desc)
            .map { component in
                AudioUnitPluginSelection(
                    id: UUID(),
                    name: component.name,
                    manufacturerName: component.manufacturerName,
                    componentType: component.audioComponentDescription.componentType,
                    componentSubType: component.audioComponentDescription.componentSubType,
                    componentManufacturer: component.audioComponentDescription.componentManufacturer
                )
            }
            .sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
    }

    func isAvailable(_ selection: AudioUnitPluginSelection) -> Bool {
        let desc = AudioComponentDescription(
            componentType: OSType(selection.componentType),
            componentSubType: OSType(selection.componentSubType),
            componentManufacturer: OSType(selection.componentManufacturer),
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return !AVAudioUnitComponentManager.shared().components(matching: desc).isEmpty
    }

    func instantiate(_ selection: AudioUnitPluginSelection) async throws -> AVAudioUnit {
        let desc = AudioComponentDescription(
            componentType: OSType(selection.componentType),
            componentSubType: OSType(selection.componentSubType),
            componentManufacturer: OSType(selection.componentManufacturer),
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard !AVAudioUnitComponentManager.shared().components(matching: desc).isEmpty else {
            throw AudioUnitPluginError.componentNotFound
        }
        // Try AUv3 out-of-process first so a 3rd-party plugin crash stays in its XPC.
        // Fall back to in-process for AUv2 / plugins that don't support OOP hosting.
        if let unit = await Self.tryInstantiate(desc: desc, options: .loadOutOfProcess) {
            return unit
        }
        if let unit = await Self.tryInstantiate(desc: desc, options: []) {
            return unit
        }
        throw AudioUnitPluginError.instantiationFailed("instantiation returned nil")
    }

    private static func tryInstantiate(
        desc: AudioComponentDescription,
        options: AudioComponentInstantiationOptions
    ) async -> AVAudioUnit? {
        await withCheckedContinuation { continuation in
            AVAudioUnit.instantiate(with: desc, options: options) { avUnit, _ in
                continuation.resume(returning: avUnit)
            }
        }
    }
}
