import AppKit
import SwiftUI

class SetupWindowController {
    private var window: NSWindow?
    private var modelManager: ModelManager?

    func showSetupWindow(modelManager: ModelManager?) {
        self.modelManager = modelManager

        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let setupView = SetupView(modelManager: modelManager)
        let hostingController = NSHostingController(rootView: setupView)
        // Size the window ourselves; the content scrolls when it's taller than the window
        hostingController.sizingOptions = [.minSize]

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Speak2 Setup"
        window.styleMask = [.titled, .closable, .resizable]
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        window.setContentSize(NSSize(width: 520, height: min(780, screenHeight - 80)))
        window.contentMaxSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Bring app to front
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func closeSetupWindow() {
        window?.close()
        window = nil
    }
}
