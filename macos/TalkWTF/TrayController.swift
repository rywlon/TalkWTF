import AppKit

/// Menu-bar item: open the window, quick dictation, quit.
final class TrayController: NSObject {
    static let shared = TrayController()
    private var item: NSStatusItem?

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

    func setVisible(_ visible: Bool) {
        if visible {
            install()
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
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
