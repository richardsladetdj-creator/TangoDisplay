import AppKit
import SwiftUI

/// Semantic color constants matching the TangoSuggest dark theme palette.
/// Applied only to the control window — the presentation window uses its own profile system.
enum ControlTheme {
    /// Accent / section-header blue. Matches TangoSuggest's #6a9fd8.
    static let accent = Color(hex: "#6a9fd8")

    /// Background for the debug log scroll region.
    static let codeBackground = Color(nsColor: .textBackgroundColor)
}
