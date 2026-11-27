import Foundation
import TangoDisplayCore

func runPlaybackRecoveryTests() {
    suite("Built-in playback recovery") {
        test("a mid-track failure advances past the failed row and any unreadable successors") {
            var interrupted = playbackEntry("Interrupted", state: .playing)
            interrupted.repeatTrack = true
            let corrupt = playbackEntry("Corrupt")
            let playable = playbackEntry("Playable")
            let successors = [interrupted.id: corrupt, corrupt.id: playable]
            var events: [String] = []

            let result = PlaybackRecovery.run(
                .recover(after: interrupted.id, error: PlaybackFailure.track("Decoder stopped")),
                nextAfter: { successors[$0] },
                attempt: { entry, bypassAutoGap in
                    events.append("Attempt \(entry.track.title), bypass gap: \(bypassAutoGap)")
                    if entry.id == corrupt.id { throw CocoaError(.fileReadCorruptFile) }
                },
                didFail: { id, _ in
                    events.append(id == interrupted.id ? "Interrupted flagged" : "Corrupt flagged")
                }
            )

            try expectEqual(events, [
                "Interrupted flagged", "Attempt Corrupt, bypass gap: true",
                "Corrupt flagged", "Attempt Playable, bypass gap: true"
            ])
            try expectStarted(result, id: playable.id)
        }

        test("an unreadable file at the start skips forward and reports the next track as started") {
            let unreadable = playbackEntry("Unreadable")
            let playable = playbackEntry("Playable")
            var attempted: [UUID] = []
            var gapsBypassed: [Bool] = []
            var failed: [UUID] = []

            let result = PlaybackRecovery.run(
                .start(unreadable, bypassAutoGap: false),
                nextAfter: { $0 == unreadable.id ? playable : nil },
                attempt: { entry, bypassAutoGap in
                    attempted.append(entry.id)
                    gapsBypassed.append(bypassAutoGap)
                    if entry.id == unreadable.id { throw CocoaError(.fileReadNoPermission) }
                },
                didFail: { id, _ in failed.append(id) }
            )

            try expectEqual(attempted, [unreadable.id, playable.id])
            try expectEqual(gapsBypassed, [false, true])
            try expectEqual(failed, [unreadable.id])
            try expectStarted(result, id: playable.id)
        }

        test("a failure on the last track ends playback without another attempt") {
            let last = playbackEntry("Last", state: .playing)
            var attempted = false
            var failed: [UUID] = []
            let result = PlaybackRecovery.run(
                .recover(after: last.id, error: PlaybackFailure.track("Stream stalled")),
                nextAfter: { _ in nil },
                attempt: { _, _ in attempted = true },
                didFail: { id, _ in failed.append(id) }
            )

            guard case .exhausted = result else {
                try expect(false, "Expected the setlist to be exhausted")
                return
            }
            try expect(!attempted)
            try expectEqual(failed, [last.id])
        }

        test("an unavailable output keeps the next track ready for retry") {
            let interrupted = playbackEntry("Interrupted", state: .playing)
            let next = playbackEntry("Next")
            let later = playbackEntry("Later")
            let successors = [interrupted.id: next, next.id: later]
            var attempted: [UUID] = []
            var failed: [UUID] = []
            let result = PlaybackRecovery.run(
                .recover(after: interrupted.id, error: PlaybackFailure.track("Stream stalled")),
                nextAfter: { successors[$0] },
                attempt: { entry, _ in
                    attempted.append(entry.id)
                    throw PlaybackFailure.outputUnavailable
                },
                didFail: { id, _ in failed.append(id) }
            )

            guard case .waitingForOutput(let pending) = result else {
                try expect(false, "Expected playback to wait for the audio output")
                return
            }
            try expectEqual(pending.id, next.id)
            let retried = PlaybackRecovery.run(
                .start(pending, bypassAutoGap: true),
                nextAfter: { successors[$0] },
                attempt: { entry, _ in attempted.append(entry.id) },
                didFail: { id, _ in failed.append(id) }
            )

            try expectStarted(retried, id: next.id)
            try expectEqual(attempted, [next.id, next.id])
            try expectEqual(failed, [interrupted.id])
        }
    }

    suite("Restoring a setlist after an app crash") {
        test("restores the last queue in order with nothing marked as playing") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("setlist.json")
            let played = playbackEntry("Played", state: .played)
            var interrupted = playbackEntry("Interrupted", state: .playing)
            interrupted.trimStartSeconds = 4
            interrupted.autoGapApplied = true
            let paused = playbackEntry("Paused", state: .paused)
            let queued = playbackEntry("Queued")
            let entries = [played, interrupted, paused, queued]
            try SetlistStore(url: url).save(entries)

            let restored = try SetlistStore(url: url).load()

            try expectEqual(restored.map(\.id), entries.map(\.id))
            try expectEqual(restored.map(\.fileURL), entries.map(\.fileURL))
            try expectEqual(restored.map(\.state), [.played, .queued, .queued, .queued])
            try expectEqual(restored[1].trimStartSeconds, 4)
            try expect(!restored[1].autoGapApplied)
        }
    }
}

private func playbackEntry(_ title: String, state: SetlistEntryState = .queued) -> SetlistEntry {
    let file = URL(fileURLWithPath: "/PlaybackRecoveryTests/\(title).wav")
    let track = Track(title: title, artist: "", genre: "", persistentID: file.path)
    return SetlistEntry(fileURL: file, track: track, state: state)
}

private func expectStarted(_ result: PlaybackRecovery.Outcome, id: UUID) throws {
    guard case .started(let entry) = result else {
        try expect(false, "Expected playback to start")
        return
    }
    try expectEqual(entry.id, id)
}
