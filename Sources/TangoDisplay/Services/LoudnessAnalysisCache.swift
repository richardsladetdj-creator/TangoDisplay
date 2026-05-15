import Foundation
import TangoDisplayCore

final class LoudnessAnalysisCache {
    static let shared = LoudnessAnalysisCache()

    private var cache: [LoudnessAnalysisCacheKey: LoudnessAnalysisResult] = [:]
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // Bump when the analysis formula changes so stale entries are silently discarded.
    // v2: BS.1770 stereo channel energy summed (not averaged); duration removed from cache key.
    private static let currentVersion = 2

    private struct CacheFile: Codable {
        let version: Int
        let entries: [LoudnessAnalysisResult]
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TangoDisplay")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("loudness-cache.json")
        load()
    }

    func result(for key: LoudnessAnalysisCacheKey) -> LoudnessAnalysisResult? {
        cache[key]
    }

    func store(_ result: LoudnessAnalysisResult) {
        cache[result.cacheKey] = result
        save()
    }

    func clear(for key: LoudnessAnalysisCacheKey) {
        cache.removeValue(forKey: key)
        save()
    }

    func clearAll() {
        cache.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? decoder.decode(CacheFile.self, from: data),
              file.version == Self.currentVersion else { return }
        cache = Dictionary(uniqueKeysWithValues: file.entries.map { ($0.cacheKey, $0) })
    }

    private func save() {
        let file = CacheFile(version: Self.currentVersion, entries: Array(cache.values))
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
