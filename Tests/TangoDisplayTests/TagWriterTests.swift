import Foundation
import TangoDisplayObjC
import TangoDisplayTagging

func runTagWriterTests() async {
    suite("Tag editing and disk verification") {}
    for ext in ["aiff", "aif", "m4a", "mp3", "wav", "flac", "opus"] {
        await testAsync("\(ext): supported fields round-trip and clear through the setlist reader") {
            let url = try copyTagFixture(ext)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let changes = [
                "TITLE": "Poema", "ARTIST": "Francisco Canaro", "GENRE": "Tango", "DATE": "1935",
                "GROUPING": "Roberto Maida", "ALBUMARTIST": "Orquesta", "COMMENT": "Original recording",
            ]
            let result = try TagFileWriter.write(changes, to: url)
            try expect(result.issues.isEmpty, "Unexpected field errors: \(result.issues)")
            try expectEqual(result.written, Set(changes.keys))
            let written = await EmbeddedTagReader.read(from: url)
            for (key, expected) in changes {
                try expectEqual(written[key], expected)
            }

            let keysToClear = ["GROUPING", "COMMENT", "ALBUMARTIST", "DATE"]
            let cleared = try TagFileWriter.write(Dictionary(uniqueKeysWithValues: keysToClear.map { ($0, "") }), to: url)
            try expect(cleared.issues.isEmpty, "Unexpected clear errors: \(cleared.issues)")
            let after = await EmbeddedTagReader.read(from: url)
            for key in keysToClear { try expectNil(after[key]) }
            try expectEqual(after["TITLE"], changes["TITLE"])
            try expectEqual(after["ARTIST"], changes["ARTIST"])
        }
    }

    test("unverified fields are reported and valid fields are saved") {
        let url = try copyTagFixture("m4a")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let unsupported = "TRACKNUMBER"
        let result = try TagFileWriter.write(["TITLE": "Poema", "DATE": "not a year", unsupported: "not a track number"], to: url)
        try expectNotNil(result.issues["DATE"])
        try expectNotNil(result.issues[unsupported])
        try expectEqual(result.written, ["TITLE"])
        let written = TDReadTags(url.path)
        try expectEqual(written?["TITLE"], "Poema")
        try expectNil(written?["DATE"])
        try expectNil(written?[unsupported])
    }

    await testAsync("ID3 grouping edits preserve a distinct work title") {
        let url = try copyTagFixture("mp3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let initial = try TagFileWriter.write(["WORK": "Independent Work"], to: url)
        try expectEqual(initial.written, ["WORK"])

        let update = try TagFileWriter.write(["GROUPING": "New Grouping"], to: url)
        try expectEqual(update.written, ["GROUPING"])
        try expectEqual(TDReadTags(url.path)?["WORK"], "Independent Work")
        let displayed = await EmbeddedTagReader.read(from: url)
        try expectEqual(displayed["GROUPING"], "New Grouping")

        let clear = try TagFileWriter.write(["GROUPING": ""], to: url)
        try expect(clear.written.isEmpty)
        try expectNotNil(clear.issues["GROUPING"])
        try expectEqual(TDReadTags(url.path)?["WORK"], "Independent Work")
        try expectEqual(TDReadTags(url.path)?["GROUPING"], "New Grouping")
    }

    test("failed replacement keeps the original bytes and cleans up the staging file") {
        let url = try copyTagFixture("aiff")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: url)
        var reachedReplacement = false
        do {
            _ = try TagFileWriter.write(["TITLE": "Poema"], to: url) { candidate, destination in
                reachedReplacement = true
                try expectEqual(destination, url.resolvingSymlinksInPath())
                try expectEqual(TDReadTags(candidate.path)?["TITLE"], "Poema")
                throw CocoaError(.fileWriteNoPermission)
            }
            try expect(false, "Expected replacement to fail")
        } catch CocoaError.fileWriteNoPermission {
            try expect(reachedReplacement)
        }
        try expectEqual(Data(contentsOf: url), original)
        try expectEqual(FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
    }
}

private func copyTagFixture(_ ext: String) throws -> URL {
    let sourceExtension = ext == "aif" ? "aiff" : ext
    guard let source = Bundle.module.url(forResource: "silence", withExtension: sourceExtension,
                                         subdirectory: "TagFixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("track.\(ext)")
    do {
        try FileManager.default.copyItem(at: source, to: file)
        return file
    } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}
