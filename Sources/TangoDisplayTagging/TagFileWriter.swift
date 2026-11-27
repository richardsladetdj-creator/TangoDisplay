import Darwin
import Foundation
import TangoDisplayObjC

package enum TagFileWriter {
    package struct Result: Sendable {
        package let written: Set<String>
        package let issues: [String: String]
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
    }

    package static func write(
        _ changes: [String: String], to url: URL,
        replace: ((URL, URL) throws -> Void)? = nil
    ) throws -> Result {
        let manager = FileManager.default
        let destination = url.resolvingSymlinksInPath()
        var pending = changes
        var issues: [String: String] = [:]
        if let year = pending["DATE"], !year.isEmpty,
           year.utf8.count != 4 || !year.utf8.allSatisfy({ (48...57).contains($0) }) {
            issues["DATE"] = "Enter a four-digit year or leave the field blank."
            pending.removeValue(forKey: "DATE")
        }

        while !pending.isEmpty {
            // Stage on the same volume, preserving the extension TagLib uses for detection.
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".tangodisplay-\(UUID().uuidString).\(url.pathExtension)")
            defer { try? manager.removeItem(at: temporary) }
            try manager.copyItem(at: destination, to: temporary)
            var rejected: NSDictionary?
            var reason: NSString?
            guard TDWriteTags(temporary.path, pending, &rejected, &reason) else {
                throw Failure(errorDescription: (reason as String?) ?? "Couldn’t write the audio tags.")
            }
            let rejectedFields = (rejected as? [String: String] ?? [:]).filter { pending[$0.key] != nil }
            if rejectedFields.isEmpty {
                try (replace ?? replaceAtomically)(temporary, destination)
                return Result(written: Set(pending.keys), issues: issues)
            }
            // Reapply accepted fields to a fresh copy so normalization or a failed clear
            // cannot change a field that the result reports as rejected.
            for (key, reason) in rejectedFields {
                pending.removeValue(forKey: key)
                issues[key] = reason
            }
        }
        return Result(written: [], issues: issues)
    }

    private static func replaceAtomically(_ source: URL, _ destination: URL) throws {
        let status = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        if status != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
