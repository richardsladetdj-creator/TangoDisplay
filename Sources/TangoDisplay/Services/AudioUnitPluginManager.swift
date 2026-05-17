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

    private static let allowedPluginNames: Set<String> = [
        "AUNBandEQ",
        "AUGraphicEQ",
        "AUDynamicsProcessor",
        "AUMultibandCompressor",
        "AUPeakLimiter",
        "AUHighShelfFilter",
        "AULowShelfFilter",
        "AUHipass",
        "AULowpass",
    ]

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
            .compactMap { component in
                guard Self.allowedPluginNames.contains(component.name) else { return nil }
                return AudioUnitPluginSelection(
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
        return try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(with: desc, options: []) { avUnit, error in
                if let error {
                    continuation.resume(throwing: AudioUnitPluginError.instantiationFailed(error.localizedDescription))
                } else if let avUnit {
                    continuation.resume(returning: avUnit)
                } else {
                    continuation.resume(throwing: AudioUnitPluginError.instantiationFailed("instantiation returned nil"))
                }
            }
        }
    }
}
