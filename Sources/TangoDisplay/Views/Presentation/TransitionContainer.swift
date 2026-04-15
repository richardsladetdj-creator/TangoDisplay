import SwiftUI
import TangoDisplayCore

struct TransitionContainer<Content: View, Identity: Hashable>: View {
    let identity: Identity
    let style: TransitionStyle
    let duration: Double
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .id(identity)
            .transition(transition(for: style))
            .animation(.easeInOut(duration: duration), value: identity)
    }

    private func transition(for style: TransitionStyle) -> AnyTransition {
        switch style {
        case .fade:
            return .opacity
        case .cut:
            return .identity
        case .fadeToBlack:
            // Fade out to black, then fade in from black
            return .asymmetric(
                insertion: .opacity.animation(.easeIn(duration: duration / 2).delay(duration / 2)),
                removal:   .opacity.animation(.easeOut(duration: duration / 2))
            )
        }
    }
}
