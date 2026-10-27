import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var notch: NotchController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.start()
        notch = NotchController()
        notch.show()
        setupStatusItem()
        registerHotKeys()

        statusItem.isVisible = Pref.menuBarIcon.bool
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusItem.isVisible = Pref.menuBarIcon.bool }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.notch.reposition() }
        }
    }

    /// Reopening Islet from Finder or Spotlight shows Settings (handy when the menu bar icon is hidden).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.eq.shutdown()
        AppState.shared.pet.save()
    }

    private func registerHotKeys() {
        let ctrlOpt = controlKey | optionKey
        HotKeys.register(kVK_ANSI_K, ctrlOpt) { [weak self] in self?.notch.openCommandPalette() }
        HotKeys.register(kVK_ANSI_M, ctrlOpt) { AppState.shared.audio.toggleMic() }
        HotKeys.register(kVK_ANSI_W, ctrlOpt) { LauncherWheel.shared.toggle() }
        HotKeys.register(kVK_ANSI_V, ctrlOpt) { PastePlain.paste() }
        HotKeys.register(kVK_Space, optionKey) { [weak self] in self?.notch.toggle() }

        let snaps: [(Int, Int, WindowSnapper.Position)] = [
            (kVK_LeftArrow, ctrlOpt, .left), (kVK_RightArrow, ctrlOpt, .right),
            (kVK_UpArrow, ctrlOpt, .maximize), (kVK_DownArrow, ctrlOpt, .center),
            (kVK_ANSI_U, ctrlOpt, .topLeft), (kVK_ANSI_I, ctrlOpt, .topRight),
            (kVK_ANSI_J, ctrlOpt, .bottomLeft), (kVK_ANSI_L, ctrlOpt, .bottomRight),
        ]
        for (key, mods, position) in snaps {
            HotKeys.register(key, mods) {
                if AppState.shared.settings.windowSnapping { WindowSnapper.snap(position) }
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Islet")

        let menu = NSMenu()
        menu.addItem(item("Open Island", #selector(openIsland)))
        menu.addItem(item("Command Palette (⌃⌥K)", #selector(openPalette)))
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        let login = item("Launch at Login", #selector(toggleLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Islet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        loginItem = login
        statusItem.menu = menu
    }

    private var loginItem: NSMenuItem?

    /// Launch at Login can also change from Settings, so refresh the check mark whenever the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openIsland() { notch.expand(sticky: true) }
    @objc private func openPalette() { notch.openCommandPalette() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            AppState.shared.hud.show(icon: "exclamationmark.triangle", text: "Move Islet to /Applications first")
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
