import AppKit

/// Menu-bar item: open the window, quick dictation, quit.
final class TrayController: NSObject {
    static let shared = TrayController()
    private var item: NSStatusItem?

    /// Set by the shell so the item can reopen the SwiftUI window after it has
    /// been closed (the `NSWindow` is gone by then, so AppKit can't restore it).
    var onOpenWindow: (() -> Void)?

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "TalkWTF"
        )
        item.button?.toolTip = "TalkWTF"

        let menu = NSMenu()
        menu.addItem(menuItem("打开 TalkWTF", #selector(showWindow)))
        menu.addItem(menuItem("开始/停止听写", #selector(toggleDictation)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出", #selector(quit), key: "q"))
        item.menu = menu
        self.item = item
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            onOpenWindow?()
        }
    }

    @objc private func toggleDictation() {
        MainActor.assumeIsolated {
            DictationController.shared.toggleFromTray()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
