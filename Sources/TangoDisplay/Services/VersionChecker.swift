import Foundation

@MainActor
final class VersionChecker: ObservableObject {

    @Published private(set) var latestVersion: String? = nil
    @Published private(set) var updateAvailable: Bool = false

    let currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

    private let releasesURL = URL(string: "https://api.github.com/repos/richardsladetdj-creator/TangoDisplay/releases/latest")!
    let releasesPageURL = URL(string: "https://github.com/richardsladetdj-creator/TangoDisplay/releases/latest")!

    private var periodicTask: Task<Void, Never>?

    func startPeriodicChecks() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func check() async {
        guard let (data, response) = try? await URLSession.shared.data(from: releasesURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONDecoder().decode(GitHubRelease.self, from: data)
        else { return }

        let tag = json.tagName.hasPrefix("v") ? String(json.tagName.dropFirst()) : json.tagName
        latestVersion = tag
        updateAvailable = isNewer(tag, than: currentVersion)
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = candidate.split(separator: ".").compactMap { Int($0) }
        let rhs = current.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(lhs.count, rhs.count)
        for i in 0..<maxLen {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
}
