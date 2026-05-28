import SwiftUI

enum TrackCounterPosition: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight, centre

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topLeft:     return "Top left"
        case .topRight:    return "Top right"
        case .bottomLeft:  return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .centre:      return "Centred (in text order)"
        }
    }

    var overlayAlignment: Alignment {
        switch self {
        case .topLeft:     return .topLeading
        case .topRight:    return .topTrailing
        case .bottomLeft:  return .bottomLeading
        case .bottomRight: return .bottomTrailing
        case .centre:      return .center
        }
    }
}
