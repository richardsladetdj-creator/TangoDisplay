import SwiftUI
import TangoDisplayCore

/// Scaled-down mirror of the PresentationView.
/// Uses scaleEffect on a fixed-size container so the presentation layout is
/// identical to the real thing, just smaller.
struct PreviewPane: View {
    @EnvironmentObject var appState: AppState

    private let previewWidth: CGFloat = 480
    private let previewHeight: CGFloat = 270
    private let targetWidth: CGFloat = 1920
    private let targetHeight: CGFloat = 1080
    private var scale: CGFloat { previewWidth / targetWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PREVIEW")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 2)

            ZStack {
                // Mirror the PresentationView at scale
                PresentationView(isPreview: true)
                    .environmentObject(appState)
                    .environmentObject(appState.settings)
                    .frame(width: targetWidth, height: targetHeight)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: previewWidth, height: previewHeight, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .clipped()

                // Border
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                    .frame(width: previewWidth, height: previewHeight)
            }
        }
        .padding()
    }
}
