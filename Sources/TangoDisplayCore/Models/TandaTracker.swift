import Foundation

public struct TandaTracker {
    public init() {}

    /// Computes tanda position when the full ordered playlist is available.
    ///
    /// Scans backward from `currentIndex` until a cortina or start of list → position within tanda.
    /// Scans forward from `currentIndex` until a cortina or end of list → total tanda length.
    ///
    /// Returns nil if `currentIndex` is out of bounds or the track at that index is itself a cortina.
    public func position(
        tracks: [Track],
        currentIndex: Int,
        detector: CortinaDetector
    ) -> TandaPosition? {
        guard currentIndex >= 0, currentIndex < tracks.count else { return nil }
        guard !detector.isCortina(genre: tracks[currentIndex].genre) else { return nil }

        // Scan backward to find start of current tanda
        var tandaStart = currentIndex
        while tandaStart > 0 && !detector.isCortina(genre: tracks[tandaStart - 1].genre) {
            tandaStart -= 1
        }

        // Scan forward to find end of current tanda
        var tandaEnd = currentIndex
        while tandaEnd + 1 < tracks.count && !detector.isCortina(genre: tracks[tandaEnd + 1].genre) {
            tandaEnd += 1
        }

        let current = currentIndex - tandaStart + 1
        let total = tandaEnd - tandaStart + 1

        return TandaPosition(current: current, total: total)
    }

    /// Computes tanda position from the history of consecutive non-cortina tracks
    /// played since the last cortina. The history is 1-based (history[0] = track 1).
    ///
    /// Returns nil if history is empty.
    public func positionFromHistory(_ history: [Track]) -> TandaPosition? {
        guard !history.isEmpty else { return nil }
        return TandaPosition(current: history.count, total: nil)
    }
}
