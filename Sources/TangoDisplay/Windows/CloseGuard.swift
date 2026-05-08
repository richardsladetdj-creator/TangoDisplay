import AppKit

/// Intercepts the window close button and asks the user to confirm before quitting.
/// Attach to any NSWindow via window.delegate = CloseGuard.shared.
final class CloseGuard: NSObject, NSWindowDelegate {

    static let shared = CloseGuard()

    private override init() { super.init() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}
