import AppKit

// Register default preferences before any model reads them (AppState builds its models on first use).
Pref.register()
Prefs.register()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
