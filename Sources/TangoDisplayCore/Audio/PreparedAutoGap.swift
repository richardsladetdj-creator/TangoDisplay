import Foundation

/// Auto-gap silence analysis bound to a specific (current, next) transition.
///
/// Binding to entry identities lets the consumer reject stale analysis after a
/// reorder, out-of-order mark-played, or skipped-over entry, where the prepared
/// leading silence would otherwise belong to the wrong track.
public struct PreparedAutoGap: Equatable, Sendable {
    public let currentID: UUID
    public let nextID: UUID
    public let trailing: Double
    public let leading: Double

    public init(currentID: UUID, nextID: UUID, trailing: Double, leading: Double) {
        self.currentID = currentID
        self.nextID = nextID
        self.trailing = trailing
        self.leading = leading
    }

    /// Injected silence for this exact transition, or nil if the pair is stale.
    public func injectedDuration(currentID: UUID, nextID: UUID, target: Double) -> Double? {
        guard self.currentID == currentID, self.nextID == nextID else { return nil }
        guard target.isFinite, target > 0 else { return 0 }
        let t = trailing.isFinite ? max(0, trailing) : 0
        let l = leading.isFinite ? max(0, leading) : 0
        return max(0, target - t - l)
    }
}
