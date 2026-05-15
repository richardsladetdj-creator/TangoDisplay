import Foundation

public struct ReplayGainInfo: Equatable, Hashable, Codable {
    public let trackGainDb: Double?
    public let trackPeak: Double?
    public let albumGainDb: Double?
    public let albumPeak: Double?

    public init(trackGainDb: Double?, trackPeak: Double?,
                albumGainDb: Double?, albumPeak: Double?) {
        self.trackGainDb = trackGainDb
        self.trackPeak   = trackPeak
        self.albumGainDb = albumGainDb
        self.albumPeak   = albumPeak
    }

    var hasAnyData: Bool {
        trackGainDb != nil || trackPeak != nil || albumGainDb != nil || albumPeak != nil
    }
}
