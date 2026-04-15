import AppKit

/// Intercepts the window close button and asks the user to confirm before quitting.
/// Attach to any NSWindow via window.delegate = CloseGuard.shared.
final class CloseGuard: NSObject, NSWindowDelegate {

    static let shared = CloseGuard()

    private override init() { super.init() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit TangoDisplay?"
        alert.informativeText = "This will close the display and stop polling Music."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
        // Always return false — either we're quitting or the user cancelled
        return false
    }
}
