import Foundation

/// Summary of one tanda (a run of non-cortina tracks between cortinas).
public struct TandaSummary: Equatable {
    public let firstID: UUID
    public let count: Int
    /// Most common genre in the tanda (original casing of its first occurrence).
    public let genre: String
    /// Orchestra shown in the header; nil when the tanda mixes orchestras or none is tagged.
    public let orchestra: String?
    public let mixedOrchestra: Bool
    public let mixedGenre: Bool
    public let mixedDecade: Bool

    public var isMixed: Bool { mixedOrchestra || mixedGenre || mixedDecade }
}

/// Per-row tanda info.
public struct TandaRowInfo: Equatable {
    public let position: Int      // 1-based
    public let total: Int
    public let summary: TandaSummary

    public var isLast: Bool { position == total }
}

public enum TandaGrouping {

    public struct Item {
        public let id: UUID
        public let track: Track
        public let isCortina: Bool

        public init(id: UUID, track: Track, isCortina: Bool) {
            self.id = id
            self.track = track
            self.isCortina = isCortina
        }
    }

    /// Groups consecutive non-cortina items into tandas. Cortinas get no entry.
    /// Positions are computed over the full list, so hiding rows doesn't renumber them.
    public static func group(_ items: [Item]) -> [UUID: TandaRowInfo] {
        var result: [UUID: TandaRowInfo] = [:]
        var run: [Item] = []

        func flush() {
            guard let first = run.first else { return }
            let summary = summarize(run, firstID: first.id)
            for (i, item) in run.enumerated() {
                result[item.id] = TandaRowInfo(position: i + 1, total: run.count, summary: summary)
            }
            run.removeAll()
        }

        for item in items {
            if item.isCortina { flush() } else { run.append(item) }
        }
        flush()
        return result
    }

    // MARK: - Summary

    static func summarize(_ run: [Item], firstID: UUID) -> TandaSummary {
        let orchestras = run.map { orchestraKey($0.track.artist) }.filter { !$0.isEmpty }
        let genres = run.map { normalize($0.track.genre) }.filter { !$0.isEmpty }
        let decades = run.compactMap { $0.track.year.map { $0 / 10 } }

        let mixedOrchestra = Set(orchestras).count > 1
        let orchestra: String? = mixedOrchestra ? nil
            : run.first(where: { !orchestraKey($0.track.artist).isEmpty })
                .map { orchestraDisplay($0.track.artist) }

        return TandaSummary(
            firstID: firstID,
            count: run.count,
            genre: dominantGenre(run),
            orchestra: orchestra,
            mixedOrchestra: mixedOrchestra,
            mixedGenre: Set(genres).count > 1,
            mixedDecade: Set(decades).count > 1
        )
    }

    private static func dominantGenre(_ run: [Item]) -> String {
        var counts: [String: (count: Int, display: String, firstIndex: Int)] = [:]
        for (i, item) in run.enumerated() {
            let key = normalize(item.track.genre)
            guard !key.isEmpty else { continue }
            let display = item.track.genre.trimmingCharacters(in: .whitespaces)
            if let c = counts[key] {
                counts[key] = (c.count + 1, c.display, c.firstIndex)
            } else {
                counts[key] = (1, display, i)
            }
        }
        // Highest count wins; ties go to the genre seen first.
        return counts.values
            .max { a, b in a.count != b.count ? a.count < b.count : a.firstIndex > b.firstIndex }?
            .display ?? ""
    }

    /// Strips singer / featured credits so "Juan D'Arienzo / Héctor Mauré" and
    /// "Juan D'Arienzo / Alberto Echagüe" count as one orchestra.
    static func orchestraDisplay(_ artist: String) -> String {
        var s = artist
        for sep in ["/", ";", " - ", " – ", " feat.", " feat ", " ft.", " con ", " canta ", " Canta ", " Con "] {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func orchestraKey(_ artist: String) -> String {
        normalize(orchestraDisplay(artist))
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }
}
