import AppKit
import Foundation
import TangoDisplayCore
import TangoDisplayTagging

enum TagEditor {
    struct Result: Sendable {
        let local: TagFileWriter.Result
        var music: TagFileWriter.Result?
        var musicWarnings: [String] = []
    }

    private struct Failure: LocalizedError { let errorDescription: String? }
    private static let worker = Worker()

    static func canWrite(_ url: URL) -> Bool {
        let fm = FileManager.default
        let destination = url.resolvingSymlinksInPath()
        return ["mp3", "m4a", "aiff", "aif", "wav", "flac", "opus"].contains(url.pathExtension.lowercased())
            && fm.isWritableFile(atPath: destination.path)
            && fm.isWritableFile(atPath: destination.deletingLastPathComponent().path)
    }

    static func apply(_ changes: [String: String], to entry: SetlistEntry) async throws -> Result {
        try await worker.apply(changes, to: entry.fileURL, musicID: entry.musicPersistentID)
    }

    // Serialize whole-file edits, including when two setlist rows refer to the same file.
    private actor Worker {
        func apply(_ changes: [String: String], to file: URL, musicID: String?) throws -> Result {
            var result = Result(local: try TagFileWriter.write(changes, to: file))
            guard !result.local.written.isEmpty, let musicID else { return result }
            guard !musicID.isEmpty, musicID.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else {
                result.musicWarnings.append("Music’s library file was not updated because the track ID is invalid.")
                return result
            }

            let musicTrack = "first track of library playlist 1 whose persistent ID is \"\(musicID)\""
            let original: URL
            do {
                guard let path = try runMusic("POSIX path of (get location of (\(musicTrack)))").stringValue,
                      !path.isEmpty else { throw Failure(errorDescription: "The track has no local file.") }
                original = URL(fileURLWithPath: path)
            } catch {
                result.musicWarnings.append("Couldn’t find Music’s library file. \(error.localizedDescription)")
                return result
            }

            if original.resolvingSymlinksInPath() != file.resolvingSymlinksInPath() {
                do {
                    let written = changes.filter { result.local.written.contains($0.key) }
                    let music = try TagFileWriter.write(written, to: original)
                    result.music = music
                    guard !music.written.isEmpty else { return result }
                } catch {
                    result.musicWarnings.append("Couldn’t update Music’s library file. \(error.localizedDescription)")
                    return result
                }
            } else {
                result.music = result.local
            }

            do {
                _ = try runMusic("refresh (\(musicTrack))")
            } catch {
                result.musicWarnings.append("Music’s file was updated, but Music couldn’t refresh its library. \(error.localizedDescription)")
            }
            return result
        }

        private func runMusic(_ statement: String) throws -> NSAppleEventDescriptor {
            var errorInfo: NSDictionary?
            let source = "tell application \"Music\"\n\(statement)\nend tell"
            guard let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo),
                  errorInfo == nil else {
                let message = errorInfo?["NSAppleScriptErrorMessage"] as? String
                throw Failure(errorDescription: message ?? "Music returned no AppleScript result.")
            }
            return result
        }
    }
}
