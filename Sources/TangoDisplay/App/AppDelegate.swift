import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    // Injected by TangoDisplayApp after initialisation
    var appState: AppState?

    private let hotkeyService = HotkeyService()
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let appState else { return }
        appState.profileStore.load()
        appState.start()
        hotkeyService.register(appState: appState)
        menuBarController = MenuBarController(appState: appState)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyService.unregister()
    }

    /// Keep the app alive when all windows are closed so polling continues
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the dock icon when windows are hidden/minimised restores them
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            WindowManager.presentationWindow?.deminiaturize(nil)
            WindowManager.presentationWindow?.makeKeyAndOrderFront(nil)
            WindowManager.showControlWindow()
        }
        return true
    }
}
