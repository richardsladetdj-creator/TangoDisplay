import AppKit

/// Registers global NSEvent monitors for ⌘⇧O (override), ⌘⇧P (pause), ⌘⇧R (force poll).
///
/// Global monitors fire even when TangoDisplay is not the frontmost app.
/// They require Input Monitoring permission (System Settings › Privacy & Security).
/// If permission is denied, addGlobalMonitorForEvents returns a non-nil token but
/// the callback is never invoked — fail silently by design.
///
/// Permission check: AXIsProcessTrusted() is a proxy for the required permission.
/// We surface a guidance message but cannot trigger the system dialog ourselves.
final class HotkeyService {

    private var monitors: [Any] = []

    // MARK: - Register

    func register(appState: AppState) {
        // Check Accessibility / Input Monitoring permission
        if !AXIsProcessTrusted() {
            NotificationCenter.default.post(name: .hotkeyPermissionRequired, object: nil)
        }

        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak appState] event in
            guard let appState else { return }
            guard event.modifierFlags.intersection([.command, .shift, .control, .option])
                    == [.command, .shift] else { return }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case "o":
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .showOverrideDialog, object: nil)
                }
            case "p":
                Task { @MainActor in appState.togglePaused() }
            case "r":
                Task { @MainActor in appState.pollNow() }
            default:
                break
            }
        }

        if let monitor {
            monitors.append(monitor)
        }
    }

    // MARK: - Unregister

    func unregister() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}
