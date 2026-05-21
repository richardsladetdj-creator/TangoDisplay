import Foundation

enum TrackInfoField: String, CaseIterable, Codable, Identifiable {
    case artist
    case title
    case year
    case albumArtist
    case comments
    case grouping

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .artist:      return "Artist"
        case .title:       return "Title"
        case .year:        return "Year"
        case .albumArtist: return "Album Artist"
        case .comments:    return "Comments"
        case .grouping:    return "Grouping"
        }
    }

    var sampleValue: String {
        switch self {
        case .artist:      return "Osvaldo Fresedo"
        case .title:       return "Arrabalero - 440 Hz"
        case .year:        return "1939"
        case .albumArtist: return "Osvaldo Fresedo"
        case .comments:    return "instrumental"
        case .grouping:    return "Vals"
        }
    }
}

struct TransformRule: Codable, Equatable {
    var enabled: Bool = false
    var pattern: String = ""
    var replacement: String = ""
    var testInput: String = ""
}
