import SwiftUI

struct VersionBadgeView: View {
    @EnvironmentObject var checker: VersionChecker

    var body: some View {
        HStack(spacing: 5) {
            dot
            Text("v\(checker.currentVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if checker.updateAvailable, let latest = checker.latestVersion {
                Button {
                    NSWorkspace.shared.open(checker.releasesPageURL)
                } label: {
                    Text("v\(latest) ↗")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Open release notes for v\(latest)")
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var dot: some View {
        let color: Color = {
            guard checker.latestVersion != nil else { return .secondary }
            return checker.updateAvailable ? .red : .green
        }()
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }
}
