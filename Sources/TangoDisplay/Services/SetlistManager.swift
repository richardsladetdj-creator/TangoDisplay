import AppKit
import AVFoundation
import Combine
import Foundation
import iTunesLibrary
import os.log
import TangoDisplayCore
import TangoDisplayTagging

enum DuplicateSessionDecision { case alwaysAdd, neverAdd }

/// Everything needed to put deleted rows back where they were.
struct SetlistRemoval {
    /// Removed entries in original order, each with the surviving entry that followed it.
    fileprivate let items: [(entry: SetlistEntry, anchorID: UUID?)]
    fileprivate let stopAfterID: UUID?
    var ids: Set<UUID> { Set(items.map(\.entry.id)) }
    var count: Int { items.count }
}

/// Setlist order before a reorder, plus each row's state so the undo can refuse
/// once playback has moved on (restoring an old order then would scramble the set).
struct SetlistReorder {
    fileprivate let order: [UUID]
    fileprivate let states: [UUID: SetlistEntryState]
}

final class SetlistManager: ObservableObject {
    @Published private(set) var entries: [SetlistEntry] = []
    @Published var stopAfterEntryID: UUID?
    @Published private(set) var mediaIssues: [UUID: String] = [:]
    @Published private(set) var persistenceError: String?
    @Published private(set) var recoveryNotice: String?
    /// Tandas folded in the setlist view, keyed by the tanda's first entry ID. Session-only.
    @Published var collapsedTandaIDs: Set<UUID> = []
    private(set) var duplicateSessionDecision: DuplicateSessionDecision? = nil

    func setDuplicateSessionDecision(_ decision: DuplicateSessionDecision?) {
        duplicateSessionDecision = decision
    }

    var totalPlaylistDuration: TimeInterval {
        entries.compactMap { $0.duration }.reduce(0, +)
    }

    private let store: SetlistStore
    private var preserveSnapshot = false
    private var hasUnsavedChanges = false
    private var missingMediaIDs: Set<UUID> = []
    private var mediaScanGeneration = 0
    private var playbackErrors: [UUID: String] = [:]

    init(storeURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = SetlistStore(url: storeURL ?? support.appendingPathComponent("TangoDisplay/setlist.json"))
        load()
    }

    // MARK: - Queue mutations (all called on main)

    func addURLs(_ urls: [URL]) {
        insertURLs(urls, before: nil)
    }

    // anchorID is the UUID of the entry to insert before; nil means append to end.
    // Capturing a UUID (rather than an Int) prevents stale-index bugs when the
    // list mutates during the async metadata read.
    func insertURLs(_ urls: [URL], before anchorID: UUID?, importMusicTimes: Bool = false,
                    musicIDs: MusicDragIDs = MusicDragIDs()) {
        let audioURLs = urls.filter { isAudioURL($0) }
        guard !audioURLs.isEmpty else { return }
        // Insert with a filename placeholder first so the row appears instantly;
        // the async metadata read below fills real tags. Reading metadata before
        // inserting made drags look like they failed, prompting a re-drag that then
        // hit a spurious duplicate warning.
        let placeholders = audioURLs.map { url in
            var e = SetlistEntry(fileURL: url,
                                 track: Track(title: url.deletingPathExtension().lastPathComponent,
                                              artist: "", genre: "", persistentID: url.path))
            e.musicPersistentID = musicIDs.persistentID(for: url)
            return e
        }
        insert(placeholders, before: anchorID)   // already calls save() + loadMissingDurations()
        for p in placeholders {
            let id = p.id, url = p.fileURL
            // Only tracks that came from a Music drag carry a persistent ID, and only they
            // get trim imported. Nothing here touches the main thread or Music itself.
            let musicID = importMusicTimes ? p.musicPersistentID : nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                let track = await SetlistManager.readMetadata(from: url)
                // Trim from Music's per-track start/stop (Song Info → Options). Normally
                // instant — draggingEntered started the scan about a second ago.
                var trim: (start: Double?, end: Double?)? = nil
                if let musicID { trim = await SetlistManager.musicTrimAsync(id: musicID) }
                guard let i = self.entries.firstIndex(where: { $0.id == id && $0.fileURL == url }) else { return }
                self.entries[i].track = track
                if let trim {
                    self.entries[i].trimStartSeconds = trim.start
                    self.entries[i].trimEndSeconds = trim.end
                }
                self.save()
            }
        }
    }

    func insert(_ newEntries: [SetlistEntry], before anchorID: UUID?) {
        let index = anchorID
            .flatMap { id in entries.firstIndex(where: { $0.id == id }) }
            ?? entries.count
        entries.insert(contentsOf: newEntries, at: index)
        save()
        loadMissingDurations()
    }

    @discardableResult
    func remove(at offsets: IndexSet) -> SetlistRemoval? {
        remove(ids: Set(offsets.compactMap { entries.indices.contains($0) ? entries[$0].id : nil }))
    }

    /// Re-inserts rows removed by `remove(ids:)`. Returns false (and changes nothing)
    /// if any of them is back in the setlist already.
    @discardableResult
    func restore(_ removal: SetlistRemoval) -> Bool {
        let present = Set(entries.map(\.id))
        guard !removal.items.isEmpty, removal.ids.isDisjoint(with: present) else { return false }
        for item in removal.items {
            var entry = item.entry
            // Deleting the current row stopped playback — it comes back as queued.
            if entry.state == .playing || entry.state == .paused { entry.state = .queued }
            let index = item.anchorID.flatMap { id in entries.firstIndex(where: { $0.id == id }) }
                ?? entries.count
            entries.insert(entry, at: index)
        }
        if stopAfterEntryID == nil, let stopID = removal.stopAfterID { stopAfterEntryID = stopID }
        save()
        loadMissingDurations()
        refreshMediaAvailability()
        return true
    }

    private func reorderSnapshot() -> SetlistReorder {
        SetlistReorder(order: entries.map(\.id),
                       states: Dictionary(entries.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Puts the setlist back in the order captured by `move`. Returns the order it
    /// replaced (for redo), or nil if rows were added/removed or any row's playback
    /// state changed since.
    @discardableResult
    func revert(_ reorder: SetlistReorder) -> SetlistReorder? {
        let current = reorderSnapshot()
        guard current.states == reorder.states, current.order != reorder.order else { return nil }
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        entries = reorder.order.compactMap { byID[$0] }
        save()
        return current
    }

    @discardableResult
    func move(from source: IndexSet, to destination: Int) -> SetlistReorder? {
        // Filter out played/playing entries — they cannot be reordered.
        // Using filter (not reject) handles the case where a playing track is
        // selected alongside queued tracks and SwiftUI includes all selected
        // indices in the drag source.
        let movable = IndexSet(source.filter {
            let s = entries[$0].state
            return s == .queued || s == .paused
        })
        guard !movable.isEmpty else { return nil }
        let before = reorderSnapshot()
        entries.move(fromOffsets: movable, toOffset: destination)
        guard entries.map(\.id) != before.order else { return nil }
        save()
        return before
    }

    func clear() {
        stopAfterEntryID = nil
        duplicateSessionDecision = nil
        entries.removeAll()
        applyMediaScan(unreadable: [])
        save()
    }

    // MARK: - Playback state tracking

    func setCurrentEntry(id: UUID, paused: Bool = false) {
        for i in entries.indices {
            if entries[i].id == id {
                entries[i].state = paused ? .paused : .playing
            } else if entries[i].state == .playing || entries[i].state == .paused {
                entries[i].state = .played
            }
        }
        save()
    }

    func markPaused(id: UUID) {
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].state = .paused
            save()
        }
    }

    func markQueued(id: UUID) {
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].state = .queued
            save()
        }
    }

    func markPlayed(id: UUID) {
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].state = .played
            save()
        }
    }

    func markPlayed(ids: Set<UUID>) {
        for i in entries.indices where ids.contains(entries[i].id) {
            entries[i].state = .played
        }
        save()
    }

    func markUnplayed(ids: Set<UUID>) {
        for i in entries.indices where ids.contains(entries[i].id) {
            entries[i].state = .queued
        }
        save()
    }

    func setAutoGapOverride(id: UUID, ignore: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].autoGapOverride = ignore
        save()
    }

    /// `skip` of nil clears the override and returns the track to the global rule.
    func setRestorationOverride(id: UUID, skip: Bool?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].restorationOverride = skip
        save()
    }

    func toggleIgnoresAutoFade(id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].ignoresAutoFade.toggle()
        save()
    }

    func setIsLastTanda(id: UUID, value: Bool) {
        for i in entries.indices { entries[i].isLastTanda = false }
        if value, let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].isLastTanda = true
        }
        save()
    }

    func setPerformance(_ value: Bool, for ids: Set<UUID>) {
        for i in entries.indices where ids.contains(entries[i].id) {
            entries[i].isPerformance = value
        }
        save()
    }

    func setRepeat(_ value: Bool, for id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].repeatTrack = value
        // stop-after and repeat are mutually exclusive on the same entry
        if value && stopAfterEntryID == id { stopAfterEntryID = nil }
        save()
    }

    func setTrim(start: Double?, end: Double?, for id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].trimStartSeconds = start
        entries[i].trimEndSeconds = end
        save()
    }

    func clearTrim(for id: UUID) { setTrim(start: nil, end: nil, for: id) }

    func setUpcomingOverride(_ o: UpcomingOverride?, for id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].upcomingOverride = (o?.isEmpty ?? true) ? nil : o
        save()
    }

    func setPluginConfiguration(_ configID: UUID?, for ids: Set<UUID>) {
        for id in ids {
            guard let i = entries.firstIndex(where: { $0.id == id }) else { continue }
            entries[i].pluginConfigurationID = configID
        }
        save()
    }

    func setTagColor(_ color: TagColor, for ids: Set<UUID>) {
        for i in entries.indices where ids.contains(entries[i].id) {
            entries[i].tagColor = color
        }
        save()
    }

    func setAutoGapApplied(id: UUID, applied: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].autoGapApplied = applied
    }

    @discardableResult
    func remove(ids: Set<UUID>) -> SetlistRemoval? {
        var items: [(entry: SetlistEntry, anchorID: UUID?)] = []
        for (i, entry) in entries.enumerated() where ids.contains(entry.id) {
            let anchor = entries[(i + 1)...].first { !ids.contains($0.id) }?.id
            items.append((entry, anchor))
        }
        guard !items.isEmpty else { return nil }
        let removedStop = stopAfterEntryID.flatMap { ids.contains($0) ? $0 : nil }
        if removedStop != nil { stopAfterEntryID = nil }
        entries.removeAll { ids.contains($0.id) }
        save()
        return SetlistRemoval(items: items, stopAfterID: removedStop)
    }

    func entry(after id: UUID) -> SetlistEntry? {
        guard let i = entries.firstIndex(where: { $0.id == id }), i + 1 < entries.count else { return nil }
        return entries[i + 1]
    }

    func firstUnplayed(after id: UUID) -> SetlistEntry? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries[(i + 1)...].first(where: isPlayable)
    }

    var firstPlayable: SetlistEntry? { entries.first(where: isPlayable) }

    func isPlayable(_ entry: SetlistEntry) -> Bool {
        entry.state != .played && mediaIssues[entry.id] == nil
    }

    func entry(before id: UUID) -> SetlistEntry? {
        guard let i = entries.firstIndex(where: { $0.id == id }), i > 0 else { return nil }
        return entries[i - 1]
    }

    // MARK: - Persistence

    private func save() {
        hasUnsavedChanges = true
        retryPersistence()
    }

    private func load() {
        let decoded: [SetlistEntry]
        do {
            decoded = try store.load()
        } catch {
            preserveSnapshot = true
            persistenceError = "Couldn’t open the saved setlist. \(error.localizedDescription)"
            return
        }
        preserveSnapshot = false
        persistenceError = nil
        entries = decoded
        // These skip entries known to be missing, so start them once the scan has landed.
        refreshMediaAvailability { [weak self] in
            guard let self else { return }
            self.loadMissingDurations()
            self.reloadEmptyMetadata()
            if !UserDefaults.standard.bool(forKey: "setlistGroupingMigrationV1") {
                self.loadMissingGroupings()
            }
        }
    }

    func retryPersistence() {
        guard hasUnsavedChanges else { load(); return }
        do {
            // Back up the unreadable file once; a failed write must not add another copy per retry.
            if preserveSnapshot {
                let backup = try store.backupSnapshot()
                preserveSnapshot = false
                recoveryNotice = "The previous setlist was saved as \(backup.lastPathComponent)."
            }
            try store.save(entries)
            hasUnsavedChanges = false
            persistenceError = nil
        } catch {
            persistenceError = "Couldn’t save the setlist. \(error.localizedDescription)"
        }
    }

    /// Re-checks every entry's file off the main thread: `isReadableFile` on a sleeping
    /// external drive blocks while it spins up. `completion` runs on main after the scan,
    /// even when a newer scan supersedes this one's results.
    func refreshMediaAvailability(completion: (@MainActor () -> Void)? = nil) {
        let files = entries.map { ($0.id, $0.fileURL) }
        mediaScanGeneration += 1
        let generation = mediaScanGeneration
        Task { @MainActor [weak self] in
            let unreadable = await Self.unreadableFiles(files)
            guard let self else { return }
            if self.mediaScanGeneration == generation {
                self.applyMediaScan(unreadable: unreadable)
            }
            completion?()
        }
    }

    private static func unreadableFiles(_ files: [(UUID, URL)]) async -> Set<UUID> {
        Set(files.filter { !FileManager.default.isReadableFile(atPath: $0.1.path) }.map(\.0))
    }

    private func applyMediaScan(unreadable: Set<UUID>) {
        let ids = Set(entries.map(\.id))
        playbackErrors = playbackErrors.filter { ids.contains($0.key) }
        missingMediaIDs = unreadable.intersection(ids)
        publishMediaIssues()
    }

    func markPlaybackFailure(id: UUID, reason: String) {
        playbackErrors[id] = reason
        setAutoGapApplied(id: id, applied: false)
        if let entry = entries.first(where: { $0.id == id }), entry.state != .played {
            markQueued(id: id)
        }
        publishMediaIssues()
    }

    func retryMedia(id: UUID) {
        guard let url = entries.first(where: { $0.id == id })?.fileURL else { return }
        playbackErrors[id] = nil
        publishMediaIssues()
        Task { @MainActor [weak self] in
            let readable = await Self.unreadableFiles([(id, url)]).isEmpty
            guard let self, self.entries.contains(where: { $0.id == id && $0.fileURL == url }) else { return }
            if readable {
                self.missingMediaIDs.remove(id)
            } else {
                self.missingMediaIDs.insert(id)
            }
            self.publishMediaIssues()
            if readable {
                self.reloadMetadata(ids: [id])
                self.loadMissingDurations()
            }
        }
    }

    private func publishMediaIssues() {
        let missing = Dictionary(uniqueKeysWithValues: missingMediaIDs.map {
            ($0, "Audio file unavailable. Reconnect its drive or relink the track.")
        })
        mediaIssues = missing.merging(playbackErrors) { missing, _ in missing }
    }

    func relink(id: UUID, to url: URL) throws {
        guard isAudioURL(url) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Choose a supported audio file."])
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[i].fileURL != url { entries[i].musicPersistentID = nil }
        entries[i].fileURL = url
        entries[i].duration = Double(file.length) / file.fileFormat.sampleRate
        playbackErrors[id] = nil
        missingMediaIDs.remove(id)   // readability checked above
        publishMediaIssues()
        save()
        Task { @MainActor [weak self] in await self?.reloadMetadata(id: id, force: true) }
    }

    /// Re-reads tags from disk for the given entries, replacing whatever is in the row.
    /// Tags are otherwise read once, at drop time — a file on a sleeping external volume
    /// returns nothing and that empty result is what gets saved. This is the retry.
    func reloadMetadata(ids: [UUID]) {
        for id in ids {
            Task { @MainActor [weak self] in await self?.reloadMetadata(id: id) }
        }
    }

    /// `force` skips the empty-read guard: straight after our own tag write the volume is
    /// evidently awake, so an empty artist and genre is what the user asked for.
    @MainActor
    func reloadMetadata(id: UUID, force: Bool = false, editedFields: Set<String> = []) async {
        guard let url = entries.first(where: { $0.id == id })?.fileURL,
              !missingMediaIDs.contains(id) else { return }
        let track = await SetlistManager.readMetadata(from: url, editedFields: editedFields)
        guard let i = entries.firstIndex(where: { $0.id == id && $0.fileURL == url }) else { return }
        // A read off a still-sleeping volume comes back empty. Never let that
        // overwrite tags the row already has — a failed retry should change nothing.
        let old = entries[i].track
        let readFoundNothing = track.artist.isEmpty && track.genre.isEmpty
        let rowHasTags = !old.artist.isEmpty || !old.genre.isEmpty
        guard force || !(readFoundNothing && rowHasTags) else { return }
        entries[i].track = track
        save()
    }

    /// A row whose artist and genre are both empty never got a successful read — either the
    /// drop-time placeholder was never replaced, or the read came back empty off a cold volume.
    /// Re-read those on every launch so an affected setlist heals itself, the way durations do.
    /// ponytail: a genuinely untagged file re-reads each launch too; one asset load, same cost
    /// as loadMissingDurations. Add a "no tags here" marker only if that shows up in profiles.
    private func reloadEmptyMetadata() {
        let ids = entries
            .filter { $0.track.artist.isEmpty && $0.track.genre.isEmpty }
            .map { $0.id }
        guard !ids.isEmpty else { return }
        reloadMetadata(ids: ids)
    }

    private func loadMissingGroupings() {
        let missingGrouping = entries.filter { $0.track.grouping == nil }
        let ids = missingGrouping.filter { !missingMediaIDs.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else {
            if missingGrouping.isEmpty {
                UserDefaults.standard.set(true, forKey: "setlistGroupingMigrationV1")
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var changed = false
            for id in ids {
                guard let idx = self.entries.firstIndex(where: { $0.id == id }) else { continue }
                let url  = self.entries[idx].fileURL
                let meta = await SetlistManager.readMetadata(from: url)
                guard let grouping = meta.grouping else { continue }
                guard let i = self.entries.firstIndex(where: { $0.id == id && $0.fileURL == url }) else { continue }
                let old = self.entries[i].track
                self.entries[i].track = Track(
                    title: old.title, artist: old.artist, genre: old.genre,
                    persistentID: old.persistentID, year: old.year,
                    comment: old.comment, albumArtist: old.albumArtist,
                    grouping: grouping, replayGainInfo: old.replayGainInfo)
                changed = true
            }
            if self.missingMediaIDs.isEmpty {
                UserDefaults.standard.set(true, forKey: "setlistGroupingMigrationV1")
            }
            if changed { self.save() }
        }
    }

    private func loadMissingDurations() {
        let needsLoad = entries.filter { $0.duration == nil && !missingMediaIDs.contains($0.id) }.map { $0.id }
        for id in needsLoad {
            Task {
                guard let idx = self.entries.firstIndex(where: { $0.id == id }) else { return }
                let url = self.entries[idx].fileURL
                let asset = AVURLAsset(url: url)
                guard let cmDuration = try? await asset.load(.duration) else { return }
                let seconds = CMTimeGetSeconds(cmDuration)
                guard seconds.isFinite && seconds > 0 else { return }
                await MainActor.run {
                    guard let i = self.entries.firstIndex(where: { $0.id == id && $0.fileURL == url }) else { return }
                    self.entries[i].duration = seconds
                    self.save()
                }
            }
        }
    }

    // MARK: - Metadata reading

    static func readMetadata(from url: URL, editedFields: Set<String> = []) async -> Track {
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.metadata)) ?? []

        // Raw-key scan for formats (FLAC/Vorbis) where AVFoundation has no typed identifier,
        // also catches stray tags where identifier mapping fails.
        func string(forRawKey rawKey: String) async -> String? {
            guard let item = metadata.first(where: { ($0.key as? String)?.lowercased() == rawKey.lowercased() }) else { return nil }
            guard let val = try? await item.load(.stringValue), !val.isEmpty else { return nil }
            return val
        }

        let tags = await EmbeddedTagReader.read(from: url, metadata: metadata)
        let library = iTunesLibrary[iTunesMediaRelativeKey(url.path)]
        let title = tags["TITLE"] ?? url.deletingPathExtension().lastPathComponent
        // A verified clear takes precedence over cached Music metadata for that field.
        let artist = tags["ARTIST"] ?? (editedFields.contains("ARTIST") ? nil : library?.artist) ?? ""
        let genre = tags["GENRE"] ?? (editedFields.contains("GENRE") ? nil : library?.genre) ?? ""
        let year = tags["DATE"].flatMap(Int.init) ?? (editedFields.contains("DATE") ? nil : library?.year)
        let grouping = tags["GROUPING"] ?? (editedFields.contains("GROUPING") ? nil : library?.grouping)

        // ID3 TXXX frame lookup (MP3 ReplayGain). The description/tag-name lives in extraAttributes[.info].
        func txxx(key: String) async -> String? {
            let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .id3MetadataUserText)
            for item in items {
                let attrs = (try? await item.load(.extraAttributes)) ?? [:]
                guard (attrs[AVMetadataExtraAttributeKey.info] as? String)?.lowercased() == key.lowercased() else { continue }
                if let val = try? await item.load(.stringValue), !val.isEmpty { return val }
            }
            return nil
        }

        // ReplayGain: Vorbis comments (FLAC) via raw key, ID3 TXXX frames (MP3), M4A raw key fallback.
        // (await cannot appear inside ?? autoclosures, so each lookup is a separate binding.)
        let rgTrackGainVorbis = await string(forRawKey: "replaygain_track_gain")
        let rgTrackGainTxxx   = await txxx(key: "replaygain_track_gain")
        let rgTrackPeakVorbis = await string(forRawKey: "replaygain_track_peak")
        let rgTrackPeakTxxx   = await txxx(key: "replaygain_track_peak")
        let rgAlbumGainVorbis = await string(forRawKey: "replaygain_album_gain")
        let rgAlbumGainTxxx   = await txxx(key: "replaygain_album_gain")
        let rgAlbumPeakVorbis = await string(forRawKey: "replaygain_album_peak")
        let rgAlbumPeakTxxx   = await txxx(key: "replaygain_album_peak")
        let rgTrackGainStr = rgTrackGainVorbis ?? rgTrackGainTxxx
        let rgTrackPeakStr = rgTrackPeakVorbis ?? rgTrackPeakTxxx
        let rgAlbumGainStr = rgAlbumGainVorbis ?? rgAlbumGainTxxx
        let rgAlbumPeakStr = rgAlbumPeakVorbis ?? rgAlbumPeakTxxx
        let rgTrackGain = parseReplayGainDb(rgTrackGainStr)
        let rgTrackPeak = Double(rgTrackPeakStr?.trimmingCharacters(in: .whitespaces) ?? "")
        let rgAlbumGain = parseReplayGainDb(rgAlbumGainStr)
        let rgAlbumPeak = Double(rgAlbumPeakStr?.trimmingCharacters(in: .whitespaces) ?? "")
        let replayGainInfo: ReplayGainInfo? = (rgTrackGain != nil || rgTrackPeak != nil || rgAlbumGain != nil || rgAlbumPeak != nil)
            ? ReplayGainInfo(trackGainDb: rgTrackGain, trackPeak: rgTrackPeak,
                             albumGainDb: rgAlbumGain, albumPeak: rgAlbumPeak)
            : nil

        return Track(
            title: title,
            artist: artist,
            genre: genre,
            persistentID: url.absoluteString,
            year: year,
            comment: tags["COMMENT"],
            albumArtist: tags["ALBUMARTIST"],
            grouping: grouping,
            replayGainInfo: replayGainInfo
        )
    }

    private struct iTunesLibraryEntry {
        let genre: String?
        let year: Int?
        let artist: String?
        let grouping: String?
    }

    // Lazy one-time parse of iTunes Library.xml → relative path key → track metadata.
    // Fallback for tracks whose genre/year/artist lives only in Music.app's library
    // and was never embedded in the file's tags.
    // Returns [:] silently if the XML is absent, unreadable, or malformed — no errors thrown.
    private static let iTunesLibrary: [String: iTunesLibraryEntry] = loadITunesLibrary()

    nonisolated static func musicTrimAsync(id: String) async -> (start: Double?, end: Double?) {
        await MusicTrimCache.shared.trim(forID: id)
    }

    // Rescans Music's start/stop table off the main thread. Called when a drag enters the
    // window — the only moment guaranteed to be after the user's edit in Music and roughly
    // a second before the drop — and once at launch, where it also triggers the Media
    // Library TCC prompt.
    nonisolated static func warmMusicTrims() {
        Task.detached(priority: .userInitiated) { await MusicTrimCache.shared.refresh() }
    }

    // Artist+title → genre lookup for players (e.g. MegaSeg) that expose no file path.
    // Parsed separately so the existing path-keyed lookup is unaffected.
    private static let iTunesGenreByArtistTitle: [String: String] = loadITunesGenreByArtistTitle()

    static func genre(forArtist artist: String, title: String) -> String? {
        iTunesGenreByArtistTitle[artistTitleLookupKey(artist, title)]
    }

    private static func artistTitleLookupKey(_ artist: String, _ title: String) -> String {
        let n: (String) -> String = { $0.decomposedStringWithCanonicalMapping.lowercased() }
        return "\(n(artist))\u{0}\(n(title))"
    }

    private static func loadITunesGenreByArtistTitle() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Music/Music/iTunes/iTunes Library.xml"),
            home.appendingPathComponent("Music/iTunes/iTunes Library.xml"),
            home.appendingPathComponent("Music/Music/iTunes/iTunes Music Library.xml"),
        ]
        for xmlURL in candidates {
            guard let data = try? Data(contentsOf: xmlURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let root = plist as? [String: Any],
                  let tracks = root["Tracks"] as? [String: Any]
            else { continue }
            var result: [String: String] = [:]
            for (_, trackAny) in tracks {
                guard let track = trackAny as? [String: Any],
                      let title  = (track["Name"]   as? String).flatMap({ $0.isEmpty ? nil : $0 }),
                      let genre  = (track["Genre"]  as? String).flatMap({ $0.isEmpty ? nil : $0 })
                else { continue }
                let artist = (track["Artist"] as? String) ?? ""
                result[artistTitleLookupKey(artist, title)] = genre
            }
            return result
        }
        return [:]
    }

    private static func loadITunesLibrary() -> [String: iTunesLibraryEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Music/Music/iTunes/iTunes Library.xml"),
            home.appendingPathComponent("Music/iTunes/iTunes Library.xml"),
            home.appendingPathComponent("Music/Music/iTunes/iTunes Music Library.xml"),
        ]
        for xmlURL in candidates {
            guard let data = try? Data(contentsOf: xmlURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let root = plist as? [String: Any],
                  let tracks = root["Tracks"] as? [String: Any]
            else { continue }

            var result: [String: iTunesLibraryEntry] = [:]
            for (_, trackAny) in tracks {
                guard let track = trackAny as? [String: Any],
                      let location = track["Location"] as? String,
                      let fileURL = URL(string: location)
                else { continue }
                // Key by the path relative to "iTunes Media/" so this works even when
                // the library was migrated from a different user account (different home prefix).
                let genre    = (track["Genre"]    as? String).flatMap { $0.isEmpty ? nil : $0 }
                let year     = track["Year"] as? Int
                let artist   = (track["Artist"]   as? String).flatMap { $0.isEmpty ? nil : $0 }
                let grouping = (track["Grouping"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                guard genre != nil || year != nil || artist != nil || grouping != nil else { continue }
                result[iTunesMediaRelativeKey(fileURL.path)] = iTunesLibraryEntry(genre: genre, year: year, artist: artist, grouping: grouping)
            }
            return result
        }
        return [:]
    }

    // Returns the substring after the last occurrence of "/iTunes Media/" (lowercased, NFD-normalised),
    // or the full lowercased path if that marker is absent.
    private static func iTunesMediaRelativeKey(_ path: String) -> String {
        let normalised = path.decomposedStringWithCanonicalMapping.lowercased()
        if let range = normalised.range(of: "/itunes media/", options: .backwards) {
            return String(normalised[range.upperBound...])
        }
        return normalised
    }

}

private func isAudioURL(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return ["mp3", "m4a", "aiff", "aif", "wav", "flac", "caf", "opus"].contains(ext)
}

private let trimLog = OSLog(subsystem: "com.tangodisplay", category: "musicdrop")

// Music's per-track start/stop (Song Info → Options), keyed by Music's persistent ID.
// Read via the iTunesLibrary framework so it works without the deprecated "Share Library
// XML" preference. Times are milliseconds.
//
// Keyed by persistent ID, never by file path: on a 24k-track library, reading
// `item.location` for every track costs ~3.9s of a ~5.3s scan, while the persistent ID
// plus the three time fields costs ~45ms on top of the unavoidable ~1.35s
// `allMediaItems`. The IDs to look up come free off the drag pasteboard (`MusicDragIDs`).
//
// Rescanned explicitly via `refresh()` when a drag enters the window and at launch — never
// lazily inside `trim(forID:)`, so a drop never waits on a scan it started itself. Users
// edit start/stop in Music mid-session, so a once-per-session snapshot goes stale.
private actor MusicTrimCache {
    static let shared = MusicTrimCache()

    private let library = try? ITLibrary(apiVersion: "1.1")
    private var times: [String: (startMs: Int, stopMs: Int, totalMs: Int)] = [:]
    private var loadedAt: Date?

    // Actor isolation does the coordination: a lookup arriving mid-scan queues behind it
    // and gets the fresh answer.
    func trim(forID id: String) -> (start: Double?, end: Double?) {
        if loadedAt == nil { reload() }
        guard let t = times[id] else { return (nil, nil) }
        return musicTrimSeconds(startMs: t.startMs, stopMs: t.stopMs, totalMs: t.totalMs)
    }

    // Rescans unless the snapshot is newer than minAge, which coalesces the repeat
    // draggingEntered calls a single hover produces.
    func refresh(minAge: TimeInterval = 1) {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < minAge { return }
        reload()
    }

    private func reload() {
        let isFirstLoad = loadedAt == nil
        loadedAt = Date()
        guard let library else { return }
        let started = Date()
        if !isFirstLoad { library.reloadData() }   // the initial ITLibrary is already fresh
        var result: [String: (startMs: Int, stopMs: Int, totalMs: Int)] = [:]
        let items = library.allMediaItems
        result.reserveCapacity(items.count)
        for item in items {
            result[String(format: "%016llX", item.persistentID.uint64Value)] =
                (item.startTime, item.stopTime, item.totalTime)
        }
        times = result
        os_log("music trim scan: %d track(s) in %.0fms", log: trimLog, type: .info,
               result.count, Date().timeIntervalSince(started) * 1000)
    }
}
