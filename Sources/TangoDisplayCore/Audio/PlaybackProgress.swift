import Foundation

public struct PlaybackProgress {
    private let startedAt: TimeInterval
    private let scheduledDuration: TimeInterval
    private var lastProgressAt: TimeInterval
    private var lastSampleTime: Int64?

    public init(startedAt: TimeInterval, scheduledDuration: TimeInterval) {
        self.startedAt = startedAt
        self.scheduledDuration = scheduledDuration
        lastProgressAt = startedAt
    }

    public mutating func hasStalled(sampleTime: Int64?, now: TimeInterval) -> Bool {
        if let sampleTime, lastSampleTime != sampleTime {
            lastSampleTime = sampleTime
            lastProgressAt = now
        }
        return now - lastProgressAt >= 3
    }

    public func endedPrematurely(now: TimeInterval) -> Bool {
        // Allow for render start, decoder frame estimates, and output latency.
        now - startedAt + max(2, scheduledDuration * 0.05) < scheduledDuration
    }
}
