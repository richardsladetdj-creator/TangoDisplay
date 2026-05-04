import AppKit

/// Manages the persistent menu bar status icon.
/// Always visible regardless of window state, providing quick access to both windows.
final class MenuBarController {

    private let statusItem: NSStatusItem
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configure()
    }

    private func configure() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "tv", accessibilityDescription: "TangoDisplay")
        image?.isTemplate = true   // adapts to light/dark menu bar automatically
        button.image = image
        button.toolTip = "TangoDisplay"
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let showDisplay = NSMenuItem(
            title: "Show Display Window",
            action: #selector(showDisplayWindow),
            keyEquivalent: ""
        )
        showDisplay.target = self
        menu.addItem(showDisplay)

        let showSettings = NSMenuItem(
            title: "Show Settings Window",
            action: #selector(showSettingsWindow),
            keyEquivalent: ""
        )
        showSettings.target = self
        menu.addItem(showSettings)

        let showSetlist = NSMenuItem(
            title: "Show Setlist",
            action: #selector(showSetlistWindow),
            keyEquivalent: ""
        )
        showSetlist.target = self
        menu.addItem(showSetlist)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit TangoDisplay",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func showDisplayWindow() {
        guard let appState else { return }
        WindowManager.showPresentationWindow(appState: appState)
    }

    @objc private func showSettingsWindow() {
        WindowManager.showControlWindow()
    }

    @objc private func showSetlistWindow() {
        WindowManager.showControlWindow()
        NotificationCenter.default.post(name: .navigateToSetlist, object: nil)
    }

    @objc private func quitApp() {
        let alert = NSAlert()
        alert.messageText = "Quit TangoDisplay?"
        alert.informativeText = "Are you sure you want to quit TangoDisplay?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSApp.terminate(nil)
    }
}
