import Foundation

package enum SetlistEntryState: String, Codable {
    case queued, playing, paused, played
}

package enum TagColor: String, Codable, CaseIterable {
    case none, red, orange, yellow, green, blue, purple
}

package struct SetlistEntry: Identifiable, Codable {
    package let id: UUID
    package var fileURL: URL
    package var track: Track
    package var state: SetlistEntryState
    package var duration: TimeInterval?
    package var autoGapOverride: Bool? = nil   // nil = follow global rule; true = force skip; false = force apply
    package var ignoresAutoFade: Bool = false
    package var isLastTanda: Bool = false      // marks this cortina as the last-tanda trigger
    package var isPerformance: Bool = false    // track is part of a guest performance
    package var repeatTrack: Bool = false      // non-dance track loops until stop-after or un-marked
    package var pluginConfigurationID: UUID? = nil
    package var tagColor: TagColor = .none
    package var trimStartSeconds: Double? = nil   // nil = play from file start
    package var trimEndSeconds: Double? = nil      // nil = play to file end
    package var restorationOverride: Bool? = nil   // nil = follow global rule; true = force skip; false = force apply
    package var upcomingOverride: UpcomingOverride? = nil  // cortina only: DJ-edited "Coming Up" details for the next tanda
    package var musicPersistentID: String? = nil   // set for Music drags — lets Edit Tags reach the library original
    package var autoGapApplied: Bool = false   // transient: true while auto-gap preroll is scheduled before this track

    enum CodingKeys: String, CodingKey {
        case id, fileURL, track, state, duration, autoGapOverride, ignoresAutoFade, isLastTanda, isPerformance, repeatTrack, pluginConfigurationID, tagColor, trimStartSeconds, trimEndSeconds, restorationOverride, upcomingOverride, musicPersistentID
        // autoGapApplied is intentionally excluded — reset each playback session
    }

    // Legacy one-directional flag (pre-tri-state); read for migration only.
    private enum LegacyKeys: String, CodingKey { case ignoresAutoGap }

    // Effective "gap skipped before this track". Assumes auto-gap is globally enabled.
    package func autoGapIgnored(isFirstTrack: Bool, ignoreFirstTrack: Bool) -> Bool {
        autoGapOverride ?? (ignoreFirstTrack && isFirstTrack)
    }

    /// Effective "restore this track". `globalDefault` already folds in the master
    /// switch and the cortina rule; an explicit override outranks both.
    package func restorationApplied(globalDefault: Bool) -> Bool {
        if let o = restorationOverride { return !o }
        return globalDefault
    }

    package init(id: UUID = UUID(), fileURL: URL, track: Track, state: SetlistEntryState = .queued) {
        self.id = id
        self.fileURL = fileURL
        self.track = track
        self.state = state
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileURL = try c.decode(URL.self, forKey: .fileURL)
        track = try c.decode(Track.self, forKey: .track)
        state = try c.decode(SetlistEntryState.self, forKey: .state)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        if let o = try c.decodeIfPresent(Bool.self, forKey: .autoGapOverride) {
            autoGapOverride = o
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            autoGapOverride = (try legacy.decodeIfPresent(Bool.self, forKey: .ignoresAutoGap) == true) ? true : nil
        }
        ignoresAutoFade = try c.decodeIfPresent(Bool.self, forKey: .ignoresAutoFade) ?? false
        isLastTanda = try c.decodeIfPresent(Bool.self, forKey: .isLastTanda) ?? false
        isPerformance = try c.decodeIfPresent(Bool.self, forKey: .isPerformance) ?? false
        repeatTrack = try c.decodeIfPresent(Bool.self, forKey: .repeatTrack) ?? false
        pluginConfigurationID = try c.decodeIfPresent(UUID.self, forKey: .pluginConfigurationID) ?? nil
        tagColor = try c.decodeIfPresent(TagColor.self, forKey: .tagColor) ?? .none
        trimStartSeconds = try c.decodeIfPresent(Double.self, forKey: .trimStartSeconds)
        trimEndSeconds = try c.decodeIfPresent(Double.self, forKey: .trimEndSeconds)
        restorationOverride = try c.decodeIfPresent(Bool.self, forKey: .restorationOverride)
        upcomingOverride = try c.decodeIfPresent(UpcomingOverride.self, forKey: .upcomingOverride)
        musicPersistentID = try c.decodeIfPresent(String.self, forKey: .musicPersistentID)
        autoGapApplied = false
    }
}
