import SwiftUI
import AppKit

/// Walks the view hierarchy to find the hosting NSWindow and delivers it to a callback.
/// Usage: .background(WindowAccessor { window in ... })
struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window {
                self.callback(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            if let window = nsView?.window {
                self.callback(window)
            }
        }
    }
}
