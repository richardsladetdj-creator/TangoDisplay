import Foundation

/// Auto-gap silence analysis bound to a specific (current, next) transition.
///
/// Binding to entry identities lets the consumer reject stale analysis after a
/// reorder, out-of-order mark-played, or skipped-over entry, where the prepared
/// leading silence would otherwise belong to the wrong track.
public struct PreparedAutoGap: Equatable, Sendable {
    public struct Adjustment: Equatable, Sendable {
        public let padding: Double
        public let leadingTrim: Double
        public let trailingTrim: Double
        public let paddingExceedsMaximum: Bool
    }

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
        adjustment(currentID: currentID, nextID: nextID, minimum: target)?.padding
    }

    public func adjustment(
        currentID: UUID, nextID: UUID, minimum: Double, maximum: Double? = nil,
        protectedPadding: Double = 0, outgoingTrimApplied: Double = 0
    ) -> Adjustment? {
        guard self.currentID == currentID, self.nextID == nextID else { return nil }
        let t = trailing.isFinite ? max(0, trailing) : 0
        let l = leading.isFinite ? max(0, leading) : 0
        let applied = outgoingTrimApplied.isFinite ? min(t, max(0, outgoingTrimApplied)) : 0
        let fixed = protectedPadding.isFinite ? max(0, protectedPadding) : 0
        let floor = minimum.isFinite ? max(0, minimum) : 0
        let gap = t - applied + l + fixed
        let limit = maximum.flatMap { $0.isFinite && $0 >= floor ? $0 : nil }
        let conflict = limit.map { fixed > $0 } ?? false
        let excess = conflict ? 0 : limit.map { max(0, gap - $0) } ?? 0
        let leadingTrim = min(l, excess)
        return Adjustment(padding: max(0, floor - gap), leadingTrim: leadingTrim,
                          trailingTrim: max(0, excess - leadingTrim), paddingExceedsMaximum: conflict)
    }
}
