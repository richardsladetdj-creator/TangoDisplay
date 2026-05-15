import SwiftUI
import TangoDisplayCore

/// Custom radio-style mode picker that allows inline per-row decoration (e.g. "Recommended" badge).
/// Used in both ReplayGainPopoverView and PlayerSettingsView.
struct ReplayGainModePicker: View {
    @Binding var mode: ReplayGainMode

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(ReplayGainMode.allCases) { m in
                HStack(spacing: 6) {
                    Image(systemName: mode == m ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(mode == m ? Color.accentColor : Color.secondary)
                        .font(.system(size: 13))
                    Text(m.displayName)
                    if m == .auto {
                        Text("Recommended")
                            .font(.system(size: 10))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { mode = m }
            }
        }
    }
}
