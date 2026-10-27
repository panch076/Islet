import AppKit
import CoreAudio
import ApplicationServices
import AVFoundation
import EventKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(_ section: SettingsSection? = nil) {
        if let section { SettingsSelection.shared.section = section }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Islet Settings"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 700, height: 460)
            w.contentView = NSHostingView(rootView: SettingsView().environment(NowPlayingModel.shared))
            w.center()
            w.setFrameAutosaveName("IsletSettings")
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, island, nowPlaying, sound, displays, alerts, clipboard, pomodoro, knock, pet, widgets, ai, windows, developer, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .island: return "Island"
        case .nowPlaying: return "Now Playing"
        case .sound: return "Sound"
        case .displays: return "Displays & HUDs"
        case .alerts: return "Alerts"
        case .clipboard: return "Clipboard & Shelf"
        case .pomodoro: return "Pomodoro"
        case .knock: return "Knock"
        case .pet: return "Desk Pet"
        case .widgets: return "Widgets & Menu Bar"
        case .ai: return "AI Usage"
        case .windows: return "Windows & Presence"
        case .developer: return "Developer"
        case .about: return "About"
        }
    }

    /// Words that make a section show up in the Settings search.
    var keywords: String {
        switch self {
        case .general: return "launch login menu bar icon capture permissions backup export import reset screen time data usage tracking"
        case .island: return "style glass black motion animation speed smooth bouncy width height display pill notch hover peek collapse delay invisible menus overlap clock date seconds font typography monochrome translucency colour color gradient corners tabs home cards double click idle lottie gestures swipe"
        case .nowPlaying: return "music lyrics karaoke shazam spectrum sync paused announce media keys player scroll title skip history desktop lyrics square art"
        case .sound: return "equalizer eq driver bass treble call microphone"
        case .displays: return "hud volume brightness ddc external monitor dim colour temperature refresh rate notch cursor ripple spotlight halo clean screen light ring video call"
        case .alerts: return "download screenshot drive caps lock keystroke focus battery full charge low messages notifications"
        case .clipboard: return "clipboard history limit pause ignore password sound auto clear tracking shelf cleanup copies"
        case .pomodoro: return "focus break long sessions sound mascot goal focus sounds rain brown noise wind waves 20-20-20 menu bar timer"
        case .knock: return "knock tap sensitivity typing protection clicks"
        case .pet: return "pet desk character animal fur colour personality bedtime fishing memories window rides outfits"
        case .widgets: return "weather city fahrenheit stocks alerts world clock desktop widgets menu bar calendar meeting join search engines"
        case .ai: return "claude codex copilot cursor tokens alert ask ai api key model"
        case .windows: return "snapping presence face lock keyboard cleaning typing sounds paste plain"
        case .developer: return "api hooks agents approvals always allow shell zsh"
        case .about: return "version about reset"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .island: return "capsule"
        case .nowPlaying: return "music.note"
        case .sound: return "speaker.wave.2"
        case .displays: return "sun.max"
        case .alerts: return "bell.badge"
        case .clipboard: return "doc.on.clipboard"
        case .pomodoro: return "timer"
        case .knock: return "hand.tap"
        case .pet: return "pawprint"
        case .widgets: return "menubar.rectangle"
        case .ai: return "sparkles"
        case .windows: return "macwindow"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsSelection: ObservableObject {
    static let shared = SettingsSelection()
    @Published var section: SettingsSection = .general
}

struct SettingsView: View {
    @ObservedObject private var selection = SettingsSelection.shared
    @State private var search = ""

    private var sections: [SettingsSection] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? SettingsSection.allCases : SettingsSection.allCases.filter {
            $0.title.lowercased().contains(q) || $0.keywords.contains(q)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(sections, selection: Binding(get: { selection.section }, set: { if let s = $0 { selection.section = s } })) { s in
                Label(s.title, systemImage: s.icon).tag(s)
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search settings")
            .onChange(of: search) { _, _ in if let first = sections.first, !sections.contains(selection.section) { selection.section = first } }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Form { content }
                .formStyle(.grouped)
                .navigationTitle(selection.section.title)
                .animation(.smooth, value: selection.section)
        }
    }

    @ViewBuilder private var content: some View {
        switch selection.section {
        case .general: GeneralSettings(); GeneralMoreSettings()
        case .island: IslandSettings(); IslandMoreSettings()
        case .nowPlaying: NowPlayingSettings(); NowPlayingMoreSettings()
        case .sound: SoundSettings()
        case .displays: DisplaySettings(); DisplayMoreSettings()
        case .alerts: AlertSettings()
        case .clipboard: ClipboardSettings()
        case .pomodoro: PomodoroSettings(); FocusMoreSettings()
        case .knock: KnockSettings()
        case .pet: PetSettings()
        case .widgets: WidgetSettings(); WidgetMoreSettings()
        case .ai: AISettings(); AskAISettings()
        case .windows: WindowSettings(); KeyboardMoreSettings()
        case .developer: DeveloperSettings(); ApprovalRulesSettings()
        case .about: AboutSettings()
        }
    }
}

// MARK: - Sections

private struct GeneralSettings: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(Pref.menuBarIcon.rawValue) private var menuBarIcon = true
    @AppStorage(Pref.hideFromCapture.rawValue) private var hideFromCapture = false
    @State private var tick = 0

    var body: some View {
        Section {
            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { on in
                do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() } catch {}
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }))
            if !Bundle.main.bundlePath.hasPrefix("/Applications") {
                Text("Move Islet to /Applications for launch at login to work.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Show menu bar icon", isOn: $menuBarIcon)
            Toggle("Hide the island from screenshots and screen recordings", isOn: $hideFromCapture)
        }
        Section("Permissions") {
            permission("Accessibility", "Window snapping, HUD replacement, keyboard tools", AXIsProcessTrusted(), "Privacy_Accessibility")
            permission("Full Disk Access", "Focus, Messages and Notification mirroring", AppState.shared.focus.accessible, "Privacy_AllFiles")
            permission("Screen & System Audio Recording", "Live spectrum, Shazam, screenshots", CGPreflightScreenCaptureAccess(), "Privacy_ScreenCapture")
            permission("Camera", "Face presence, camera mirror", AVCaptureDevice.authorizationStatus(for: .video) == .authorized, "Privacy_Camera")
            permission("Microphone", "Knock (microphone mode)", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Privacy_Microphone")
            permission("Calendars", "Calendar card, menu bar calendar", AppState.shared.calendar.authorized, "Privacy_Calendars")
            Button("Refresh") { tick += 1 }
        }
        .id(tick)
    }

    private func permission(_ name: String, _ use: String, _ granted: Bool, _ pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(name)
                Text(use).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!) }
            }
        }
    }
}

private struct IslandSettings: View {
    @ObservedObject private var settings = AppState.shared.settings
    @AppStorage(Pref.peekOnHover.rawValue) private var peek = true
    @AppStorage(Pref.peekDelay.rawValue) private var peekDelay = 0.06
    @AppStorage(Pref.panelWidth.rawValue) private var width = 640.0
    @AppStorage(Pref.panelHeight.rawValue) private var height = 230.0
    @AppStorage(Pref.pillOffset.rawValue) private var pillOffset = 4.0
    @AppStorage(Pref.pillOnNotch.rawValue) private var pillOnNotch = false
    @AppStorage(Pref.targetDisplay.rawValue) private var targetDisplay = "auto"
    @AppStorage(Pref.hideInFullscreen.rawValue) private var hideInFullscreen = true
    @AppStorage(Pref.openAnimation.rawValue) private var animation = "smooth"
    @AppStorage(Pref.idleAnimation.rawValue) private var idle = "clock"
    @AppStorage(Pref.lottiePath.rawValue) private var lottiePath = ""
    @AppStorage(Pref.lottieSpeed.rawValue) private var lottieSpeed = 1.0
    @AppStorage(Pref.lottieScale.rawValue) private var lottieScale = 1.0
    @AppStorage(Pref.lottieOffset.rawValue) private var lottieOffset = 0.0
    @AppStorage(Pref.multipleActivities.rawValue) private var multiple = true
    @AppStorage(Pref.gestureSwipeOpen.rawValue) private var swipeOpen = true
    @AppStorage(Pref.gestureSkip.rawValue) private var swipeSkip = true

    var body: some View {
        Section("Look") {
            Picker("Style", selection: $settings.islandStyle) {
                Text("Black").tag(SettingsModel.IslandStyle.black)
                Text("Liquid Glass").tag(SettingsModel.IslandStyle.glass)
            }
            Picker("Animation", selection: $animation) {
                Text("Smooth").tag("smooth")
                Text("Snappy").tag("snappy")
                Text("Bouncy").tag("bouncy")
            }
            LabeledContent("Width") { Slider(value: $width, in: 480...900, step: 10) { Text("\(Int(width))") } }
            LabeledContent("Height") { Slider(value: $height, in: 180...360, step: 10) { Text("\(Int(height))") } }
            HStack {
                Text("Presets")
                Spacer()
                Button("Compact") { width = 560; height = 210 }
                Button("Standard") { width = 640; height = 230 }
                Button("Large") { width = 760; height = 290 }
            }
        }
        Section("Placement") {
            Picker("Display", selection: $targetDisplay) {
                Text("Automatic").tag("auto")
                ForEach(NSScreen.screens, id: \.localizedName) { Text($0.localizedName).tag($0.localizedName) }
            }
            Toggle("Use the pill shape on Macs with a notch", isOn: $pillOnNotch)
            LabeledContent("Pill distance from top") { Slider(value: $pillOffset, in: 0...30, step: 1) { Text("\(Int(pillOffset)) pt") } }
            Toggle("Hide while an app is full screen", isOn: $hideInFullscreen)
        }
        Section("Opening") {
            Toggle("Open on hover", isOn: $settings.hoverToOpen)
            LabeledContent("Hover delay") { Slider(value: $settings.hoverDelay, in: 0...1) { Text(String(format: "%.2fs", settings.hoverDelay)) } }
            Toggle("Peek: show a mini player on a quick hover", isOn: $peek)
            LabeledContent("Peek delay") { Slider(value: $peekDelay, in: 0.03...0.5) { Text("\(Int(peekDelay * 1000)) ms") } }
            Toggle("Gestures", isOn: $settings.gestures)
            Toggle("Swipe down to open", isOn: $swipeOpen).disabled(!settings.gestures)
            Toggle("Swipe sideways to skip tracks", isOn: $swipeSkip).disabled(!settings.gestures)
        }
        Section("When idle") {
            Picker("Show", selection: $idle) {
                Text("Nothing").tag("none")
                Text("Clock").tag("clock")
                Text("Weather").tag("weather")
                Text("Breathing dot").tag("breathing")
                Text("Lottie animation").tag("lottie")
            }
            if idle == "lottie" {
                HStack {
                    Text(lottiePath.isEmpty ? "No file chosen" : (lottiePath as NSString).lastPathComponent).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose JSON…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.json]
                        if panel.runModal() == .OK, let url = panel.url { lottiePath = url.path }
                    }
                }
                LabeledContent("Speed") { Slider(value: $lottieSpeed, in: 0.25...3) }
                LabeledContent("Scale") { Slider(value: $lottieScale, in: 0.5...2) }
                LabeledContent("Vertical offset") { Slider(value: $lottieOffset, in: -10...10) }
            }
            Toggle("Show two live activities at once", isOn: $multiple)
        }
    }
}

private struct NowPlayingSettings: View {
    @AppStorage(Prefs.shazamEnabled) private var shazam = false
    @AppStorage(Prefs.syncOffset) private var syncOffset = 0.0
    @AppStorage(Prefs.karaokeSweep) private var karaoke = true
    @AppStorage(Prefs.fontScale) private var fontScale = 1.0
    @AppStorage(Pref.spectrum.rawValue) private var spectrum = false

    var body: some View {
        Section("Sources") {
            Text("Apple Music, Spotify, Kaset, and YouTube Music in Chrome or Safari are read directly.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Identify other music with Shazam", isOn: Binding(get: { shazam }, set: {
                shazam = $0
                NowPlayingModel.shared.setShazamEnabled($0)
            }))
            Text("Listens to system audio (needs Screen & System Audio Recording).").font(.caption).foregroundStyle(.secondary)
            if !NowPlayingModel.shared.blockedBrowsers.isEmpty {
                Text("To read YouTube Music in \(NowPlayingModel.shared.blockedBrowsers.map(\.title).joined(separator: ", ")), enable View → Developer → Allow JavaScript from Apple Events.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        Section("Lyrics") {
            Toggle("Karaoke sweep", isOn: $karaoke)
            LabeledContent("Sync offset") { Slider(value: $syncOffset, in: -3...3, step: 0.1) { Text(String(format: "%+.1fs", syncOffset)) } }
            LabeledContent("Full-screen text size") { Slider(value: $fontScale, in: 0.7...1.6) }
            Button("Open Full-Screen Lyrics") { FullScreenLyrics.shared.show() }
        }
        Section("Visualizer") {
            Toggle("Live audio spectrum (real FFT of system audio)", isOn: $spectrum)
        }
    }
}

private struct SoundSettings: View {
    @ObservedObject private var eq = AppState.shared.eq
    @ObservedObject private var settings = AppState.shared.settings

    var body: some View {
        Section("Equalizer") {
            LabeledContent("Islet Audio driver") {
                HStack {
                    Text(eq.driverInstalled ? "Installed" : "Not installed").foregroundStyle(eq.driverInstalled ? .green : .secondary)
                    Button(eq.driverInstalled ? "Reinstall…" : "Install…") { eq.installDriver() }
                    if eq.driverInstalled { Button("Uninstall…") { eq.uninstallDriver() } }
                }
            }
            Toggle("Equalizer", isOn: Binding(get: { eq.enabled }, set: { eq.setEnabled($0) })).disabled(!eq.driverInstalled)
            Picker("Play through", selection: Binding(get: { eq.selectedOutput ?? 0 }, set: { eq.route(to: $0) })) {
                if eq.selectedOutput == nil { Text("Choose speakers…").tag(AudioDeviceID(0)) }
                ForEach(eq.outputChoices) { Text($0.name).tag($0.id) }
            }
            LabeledContent("Bass") { Slider(value: $eq.low, in: -12...12) { Text(String(format: "%+.0f dB", eq.low)) } }
            LabeledContent("Mid") { Slider(value: $eq.mid, in: -12...12) { Text(String(format: "%+.0f dB", eq.mid)) } }
            LabeledContent("Treble") { Slider(value: $eq.high, in: -12...12) { Text(String(format: "%+.0f dB", eq.high)) } }
            Picker("Preset", selection: Binding(get: { "" }, set: { name in
                if let p = EQModel.presets.first(where: { $0.name == name }) { eq.applyPreset(p) }
            })) {
                Text("Choose…").tag("")
                ForEach(EQModel.presets, id: \.name) { Text($0.name).tag($0.name) }
            }
            if let error = eq.error { Text(error).foregroundStyle(.red).font(.caption) }
            Text("Apps play into “Islet Audio”; Islet filters the sound and sends it to your speakers. Volume keys keep working.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Microphone") {
            Toggle("Call island (shows calls in Zoom, FaceTime, Discord…)", isOn: $settings.callIsland)
            Text("Mute or unmute any time with ⌃⌥M.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DisplaySettings: View {
    @ObservedObject private var settings = AppState.shared.settings
    @AppStorage(Pref.hudStyle.rawValue) private var hudStyle = "island"
    @AppStorage(Pref.hudSize.rawValue) private var hudSize = 1.0
    @AppStorage(Pref.externalBrightness.rawValue) private var external = true
    @AppStorage(Pref.hideNotch.rawValue) private var hideNotch = false
    @State private var displays: [(CGDirectDisplayID, String, Double)] = []

    var body: some View {
        Section("HUDs") {
            Toggle("Replace the system volume & brightness HUD", isOn: $settings.replaceSystemHUD)
            Toggle("Show volume changes", isOn: $settings.volumeHUD)
            Picker("HUD style", selection: $hudStyle) {
                Text("In the island").tag("island")
                Text("Edge bar").tag("edge")
                Text("Circular gauge").tag("gauge")
            }
            if hudStyle != "island" {
                LabeledContent("Size") { Slider(value: $hudSize, in: 0.6...1.6) }
                Button("Preview") { AppState.shared.hud.show(icon: "speaker.wave.2.fill", text: "60%", progress: 0.6, seconds: 1.5) }
            }
        }
        Section("External displays") {
            Toggle("Brightness keys control external monitors (DDC)", isOn: $external)
            if displays.isEmpty {
                Text("No DDC-capable external displays found yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(displays, id: \.0) { id, name, value in
                LabeledContent(name) {
                    Slider(value: Binding(get: { value }, set: { v in
                        if let i = displays.firstIndex(where: { $0.0 == id }) { displays[i].2 = v }
                        ExternalBrightness.set(id, fraction: v)
                    }), in: 0...1)
                }
            }
        }
        Section("Notch") {
            Toggle("Hide the notch (black menu bar strip)", isOn: $hideNotch)
            if KeyboardBacklight.isAvailable {
                Text("Keyboard backlight keys are handled when the HUD replacement is on.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { ExternalBrightness.load { displays = $0 } }
    }
}

private struct AlertSettings: View {
    @ObservedObject private var settings = AppState.shared.settings
    @ObservedObject private var feeds = AppState.shared.feeds
    @ObservedObject private var focus = AppState.shared.focus
    @AppStorage(Pref.capsLockHUD.rawValue) private var capsLock = true
    @AppStorage(Pref.keystrokeHUD.rawValue) private var keystrokes = false
    @AppStorage(Pref.fullChargeAlert.rawValue) private var fullCharge = true
    @AppStorage(Pref.lowBatteryAlert.rawValue) private var lowBattery = true
    @AppStorage(Pref.messageIsland.rawValue) private var messages = false
    @AppStorage(Pref.notificationMirror.rawValue) private var notifications = false
    @AppStorage(Pref.screenshotShelf.rawValue) private var screenshots = true
    @AppStorage(Pref.driveAlerts.rawValue) private var drives = true

    var body: some View {
        Section("System") {
            Toggle("Download alerts", isOn: $settings.downloadAlerts)
            Toggle("Add new screenshots to the Shelf", isOn: $screenshots)
            Toggle("Drive connected / ejected", isOn: $drives)
            Toggle("Caps Lock HUD", isOn: $capsLock)
            Toggle("Keystroke HUD (show shortcuts as you press them)", isOn: $keystrokes)
            Toggle("Focus mode alerts", isOn: $settings.focusAlerts)
            if !focus.accessible { Text("Needs Full Disk Access.").font(.caption).foregroundStyle(.orange) }
        }
        Section("Battery") {
            Toggle("Full charge island", isOn: $fullCharge)
            Toggle("Low battery alerts (20% and 10%)", isOn: $lowBattery)
        }
        Section("Messages & notifications") {
            Toggle("Message island (new iMessages / SMS)", isOn: $messages)
            if messages && !feeds.messagesAccessible { Text("Needs Full Disk Access.").font(.caption).foregroundStyle(.orange) }
            Toggle("Mirror notifications into the island", isOn: $notifications)
            if notifications && !feeds.notificationsAccessible { Text("Needs Full Disk Access.").font(.caption).foregroundStyle(.orange) }
            Text("Both read macOS's own databases locally; nothing leaves your Mac.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PomodoroSettings: View {
    @ObservedObject private var pomodoro = AppState.shared.pomodoro
    @AppStorage(Pref.pomoLongBreak.rawValue) private var longBreak = 15
    @AppStorage(Pref.pomoLongEvery.rawValue) private var longEvery = 4
    @AppStorage(Pref.pomoAutoBreak.rawValue) private var autoBreak = true
    @AppStorage(Pref.pomoAutoFocus.rawValue) private var autoFocus = false
    @AppStorage(Pref.pomoGoal.rawValue) private var goal = 8
    @AppStorage(Pref.pomoSound.rawValue) private var sound = "Glass"
    @AppStorage(Pref.mascot.rawValue) private var mascot = "🐢"

    var body: some View {
        Section("Sessions") {
            Stepper("Focus: \(pomodoro.focusMinutes) min", value: $pomodoro.focusMinutes, in: 1...180)
            Stepper("Short break: \(pomodoro.breakMinutes) min", value: $pomodoro.breakMinutes, in: 1...60)
            Stepper("Long break: \(longBreak) min", value: $longBreak, in: 1...90)
            Stepper("Long break every \(longEvery) sessions", value: $longEvery, in: 1...12)
            Toggle("Start breaks automatically", isOn: $autoBreak)
            Toggle("Start focus automatically after a break", isOn: $autoFocus)
            Stepper("Daily goal: \(goal) sessions", value: $goal, in: 1...24)
        }
        Section("Style") {
            Picker("Sound", selection: $sound) {
                ForEach(["Glass", "Hero", "Ping", "Purr", "Submarine", "Funk", "Pop"], id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: sound) { _, s in NSSound(named: NSSound.Name(s))?.play() }
            Picker("Timer mascot", selection: $mascot) {
                ForEach(["🐢", "🐇", "🐈", "🦊", "🐙", "🚀", "🐝", "🍅"], id: \.self) { Text($0).tag($0) }
            }
        }
    }
}

private struct KnockSettings: View {
    @ObservedObject private var knock = AppState.shared.knock
    @AppStorage(Pref.knockEnabled.rawValue) private var enabled = false
    @AppStorage(Pref.knockMethod.rawValue) private var method = "microphone"
    @AppStorage(Pref.knockKey.rawValue) private var key = "Right Option"
    @AppStorage(Pref.knockSensitivity.rawValue) private var sensitivity = 0.5
    @AppStorage(Pref.knockSingle.rawValue) private var single = "none"
    @AppStorage(Pref.knockDouble.rawValue) private var double = "toggleIsland"
    @AppStorage(Pref.knockTriple.rawValue) private var triple = "playPause"
    @AppStorage(Pref.typingProtection.rawValue) private var typingProtection = true

    var body: some View {
        Section {
            Toggle("Knock to Control", isOn: $enabled)
            Picker("Detect knocks with", selection: $method) {
                ForEach(KnockModel.Method.allCases) { Text($0.title).tag($0.rawValue) }
            }
            if method == "key" {
                Picker("Key", selection: $key) {
                    ForEach(KnockModel.keys, id: \.name) { Text($0.name).tag($0.name) }
                }
            } else {
                LabeledContent("Sensitivity") { Slider(value: $sensitivity, in: 0...1) }
                if method == "microphone", knock.running {
                    LabeledContent("Input level") { ProgressView(value: Double(min(knock.level, 1))) }
                }
                Toggle("Typing protection", isOn: $typingProtection)
                Toggle("Ignore trackpad clicks and scrolling", isOn: Binding(get: { Pref.knockIgnoreClicks.bool }, set: { Pref.knockIgnoreClicks.set($0) }))
            }
            if !knock.status.isEmpty { Text(knock.status).font(.caption).foregroundStyle(.secondary) }
        }
        Section("Actions") {
            if method != "key" { action("Single knock", $single) }
            action("Double knock", $double)
            action("Triple knock", $triple)
        }
    }

    private func action(_ title: String, _ value: Binding<String>) -> some View {
        Picker(title, selection: value) {
            ForEach(KnockModel.Action.allCases) { Text($0.title).tag($0.rawValue) }
        }
    }
}

private struct WidgetSettings: View {
    @AppStorage(Pref.weatherCity.rawValue) private var city = ""
    @AppStorage(Pref.weatherFahrenheit.rawValue) private var fahrenheit = false
    @AppStorage(Pref.stocks.rawValue) private var stocks = "AAPL,MSFT,NVDA"
    @AppStorage(Pref.desktopWidgets.rawValue) private var desktopWidgets = false
    @AppStorage(Pref.menuBarCalendar.rawValue) private var menuBarCalendar = false
    @AppStorage(Pref.menuBarIconHiding.rawValue) private var iconHiding = false
    @AppStorage(Pref.menuBarDetach.rawValue) private var detach = false

    var body: some View {
        Section("Weather") {
            TextField("City (leave empty to use your location)", text: $city)
            Toggle("Fahrenheit", isOn: $fahrenheit)
        }
        Section("Stocks") {
            TextField("Symbols, comma separated", text: $stocks)
        }
        Section("Desktop") {
            Toggle("Desktop widgets (clock, weather, stats)", isOn: $desktopWidgets)
        }
        Section("Menu bar") {
            Toggle("Calendar in the menu bar", isOn: $menuBarCalendar)
            Toggle("Hide menu bar icons behind a chevron", isOn: $iconHiding)
            if iconHiding { Text("⌘-drag icons to the left of the │ divider to hide them.").font(.caption).foregroundStyle(.secondary) }
            Toggle("Detach: show the island in the menu bar instead of the notch", isOn: $detach)
        }
    }
}

private struct AISettings: View {
    @ObservedObject private var settings = AppState.shared.settings
    @AppStorage(Pref.aiShowClaude.rawValue) private var claude = true
    @AppStorage(Pref.aiShowCodex.rawValue) private var codex = true
    @AppStorage(Pref.aiShowCopilot.rawValue) private var copilot = true
    @AppStorage(Pref.aiShowCursor.rawValue) private var cursor = true
    @AppStorage(Pref.copilotAlert.rawValue) private var copilotAlert = 10

    var body: some View {
        Section("Providers") {
            Toggle("Claude Code", isOn: $claude)
            Toggle("Codex", isOn: $codex)
            Toggle("GitHub Copilot", isOn: $copilot)
            Toggle("Cursor", isOn: $cursor)
        }
        Section("Alerts") {
            Stepper(settings.aiDailyTokenAlert == 0 ? "Daily token alert: off" : "Daily token alert: \(settings.aiDailyTokenAlert)M",
                    value: $settings.aiDailyTokenAlert, in: 0...500, step: 5)
            Stepper("Copilot alert below \(copilotAlert)% left", value: $copilotAlert, in: 0...50, step: 5)
        }
    }
}

private struct WindowSettings: View {
    @ObservedObject private var settings = AppState.shared.settings
    @ObservedObject private var presence = AppState.shared.presence

    var body: some View {
        Section("Window snapping") {
            Toggle("Snap windows with ⌃⌥ + arrows (halves), U I J L (quarters)", isOn: $settings.windowSnapping)
            if !AXIsProcessTrusted() { Text("Needs Accessibility.").font(.caption).foregroundStyle(.orange) }
        }
        Section("Face presence") {
            Toggle("Lock when I walk away, wake the screen when I'm back", isOn: $settings.presenceLock)
            Stepper("Lock after \(settings.presenceTimeout) s away", value: $settings.presenceTimeout, in: 15...600, step: 15)
            if presence.running {
                Label(presence.faceVisible ? "Face detected" : "No face", systemImage: presence.faceVisible ? "person.fill.checkmark" : "person.fill.questionmark")
                    .foregroundStyle(presence.faceVisible ? .green : .secondary)
            }
            if let e = presence.error { Text(e).foregroundStyle(.red) }
            Text("Unlocking still uses Touch ID, Apple Watch or your password — Islet never stores your password.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Keyboard") {
            Button("Lock keyboard for cleaning (45 s)") { AppState.shared.keyboardTools.startCleaning() }
            Button("Clean screen (black out all displays)") { CleanScreen.start() }
        }
    }
}

private struct DeveloperSettings: View {
    @ObservedObject private var settings = AppState.shared.settings
    @AppStorage(Pref.agentApprovals.rawValue) private var approvals = false

    var body: some View {
        Section("Local API") {
            Toggle("Local API on 127.0.0.1:\(String(SettingsModel.apiPort))", isOn: $settings.localAPI)
            Text("GET /status · /notify?text= · /agent · /shell · POST /approve").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        Section("Coding agents") {
            copyRow("Claude Code activity hooks", "~/.claude/settings.json", AgentModel.claudeHooks)
            Toggle("Agent approvals: answer permission prompts from the island", isOn: $approvals)
            copyRow("Claude Code approval hook", "~/.claude/settings.json", AgentModel.claudeApprovalHook)
            copyRow("Codex notify", "~/.codex/config.toml", AgentModel.codexNotify)
        }
        .disabled(!settings.localAPI)
        Section("Shell activity") {
            copyRow("zsh hooks", "~/.zshrc", ShellModel.zshSnippet)
            Text("Long-running commands show in the island; you get a ✓ / ✗ when they finish.").font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!settings.localAPI)
    }

    private func copyRow(_ title: String, _ file: String, _ text: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text("Paste into \(file)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}

private struct AboutSettings: View {
    @State private var confirmReset = false

    /// Removes only preference keys (not notes, history or other data), then relaunches so every model reloads.
    static func resetSettings() {
        let settingKeys = ["hoverToOpen", "hoverDelay", "panelSize", "gestures", "volumeHUD", "downloadAlerts", "windowSnapping",
                           "localAPI", "aiDailyTokenAlert", "islandStyle", "replaceSystemHUD", "focusAlerts", "callIsland",
                           "presenceLock", "presenceTimeout"]
        for key in Array(Pref.defaults.keys) + settingKeys { UserDefaults.standard.removeObject(forKey: key) }
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    var body: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "capsule.fill").font(.system(size: 40)).foregroundStyle(.linearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom))
                VStack(alignment: .leading) {
                    Text("Islet").font(.title2.bold())
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")").foregroundStyle(.secondary)
                    Text("Free and built from source in ~/Islet. Rebuild with ./build.sh to update.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Section {
            Button("Reset all settings…", role: .destructive) { confirmReset = true }
                .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
                    Button("Reset and Relaunch", role: .destructive) { Self.resetSettings() }
                } message: {
                    Text("Preferences go back to their defaults. Notes, clipboard history, the shelf and other data are kept.")
                }
        }
    }
}

// MARK: - More settings (Notchy parity)

/// A ColorPicker bound to a "#RRGGBB" preference.
private struct HexColorPicker: View {
    let title: String
    @Binding var hex: String

    var body: some View {
        ColorPicker(title, selection: Binding(get: { Color(hex: hex) }, set: { hex = $0.hex }), supportsOpacity: false)
    }
}

private struct GeneralMoreSettings: View {
    @AppStorage(Pref.screenTime.rawValue) private var screenTime = true
    @AppStorage(Pref.dataUsage.rawValue) private var dataUsage = true

    var body: some View {
        Section("Tracking (stays on your Mac)") {
            Toggle("Screen time per app", isOn: $screenTime)
            Toggle("Network data usage", isOn: $dataUsage)
        }
        Section("Backup") {
            HStack {
                Button("Export Settings…") { SettingsBackup.export() }
                Button("Import Settings…") { SettingsBackup.import() }
            }
        }
    }
}

private struct IslandMoreSettings: View {
    @AppStorage(Pref.animationSpeed.rawValue) private var speed = 1.0
    @AppStorage(Pref.collapseDelay.rawValue) private var collapseDelay = 0.35
    @AppStorage(Pref.invisibleUntilHover.rawValue) private var invisible = false
    @AppStorage(Pref.hideIfMenusOverlap.rawValue) private var menusOverlap = false
    @AppStorage(Pref.pillHeight.rawValue) private var pillHeight = 0.0
    @AppStorage(Pref.doubleClickOpen.rawValue) private var doubleClick = false
    @AppStorage(Pref.clockFormat.rawValue) private var clockFormat = "time"
    @AppStorage(Pref.dateFormat.rawValue) private var dateFormat = 0
    @AppStorage(Pref.clockSeconds.rawValue) private var seconds = false
    @AppStorage(Pref.fontDesign.rawValue) private var font = "rounded"
    @AppStorage(Pref.monochrome.rawValue) private var monochrome = false
    @AppStorage(Pref.translucency.rawValue) private var translucency = 0.35
    @AppStorage(Pref.customColors.rawValue) private var customColors = false
    @AppStorage(Pref.pillColor.rawValue) private var pillColor = "#000000"
    @AppStorage(Pref.panelColor.rawValue) private var panelColor = "#000000"
    @AppStorage(Pref.panelGradient.rawValue) private var gradient = false
    @AppStorage(Pref.panelColor2.rawValue) private var panelColor2 = "#1E1B4B"
    @AppStorage(Pref.blackCorners.rawValue) private var corners = false
    @AppStorage(Pref.cornerRadius.rawValue) private var cornerRadius = 10.0
    @AppStorage(Pref.tabsHidden.rawValue) private var tabsHidden = ""
    @AppStorage(Pref.defaultTab.rawValue) private var defaultTab = "home"
    @AppStorage(Pref.homeCards.rawValue) private var homeCards = "nowPlaying,calendar"

    var body: some View {
        Section("Motion") {
            LabeledContent("Animation speed") { Slider(value: $speed, in: 0.5...2) { Text(String(format: "%.1f×", speed)) } }
            LabeledContent("Collapse delay") {
                Slider(value: $collapseDelay, in: 0...2, step: 0.05) { Text(collapseDelay < 0.05 ? "Instant" : String(format: "%.2fs", collapseDelay)) }
            }
            Text("Reduce Motion in macOS Accessibility settings is respected.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Visibility") {
            Toggle("Invisible until hover", isOn: $invisible)
            Toggle("Hide if menus overlap", isOn: $menusOverlap)
            Toggle("Double-click to open (instead of hover)", isOn: $doubleClick)
            LabeledContent("Pill height") { Slider(value: $pillHeight, in: -6...12, step: 1) { Text("\(Int(pillHeight + 30)) pt") } }
        }
        Section("Clock") {
            Picker("Show", selection: $clockFormat) {
                Text("Time").tag("time"); Text("Date").tag("date"); Text("Date and time").tag("both")
            }
            Picker("Date format", selection: $dateFormat) {
                let d = Date()
                Text(d.formatted(.dateTime.weekday(.abbreviated).day())).tag(0)
                Text(d.formatted(.dateTime.month(.abbreviated).day())).tag(1)
                Text(d.formatted(.dateTime.day().month(.twoDigits))).tag(2)
                Text(d.formatted(.dateTime.month(.twoDigits).day())).tag(3)
                Text(d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).tag(4)
            }
            Toggle("Show seconds", isOn: $seconds)
        }
        Section("Appearance") {
            Picker("Typography", selection: $font) {
                Text("Rounded").tag("rounded"); Text("System").tag("default"); Text("Serif").tag("serif"); Text("Monospaced").tag("monospaced")
            }
            Toggle("Monochrome interface", isOn: $monochrome)
            LabeledContent("Glass translucency") { Slider(value: $translucency, in: 0...0.9) }
            Toggle("Custom colours", isOn: $customColors)
            if customColors {
                HexColorPicker(title: "Pill", hex: $pillColor)
                HexColorPicker(title: "Panel", hex: $panelColor)
                Toggle("Gradient panel", isOn: $gradient)
                if gradient { HexColorPicker(title: "Gradient end", hex: $panelColor2) }
                Button("Same as panel") { pillColor = panelColor }
            }
            Toggle("Black out screen corners", isOn: $corners)
            if corners { LabeledContent("Corner radius") { Slider(value: $cornerRadius, in: 4...30, step: 1) } }
        }
        Section("Tabs") {
            Picker("Open to", selection: $defaultTab) {
                Text("Last used tab").tag("last")
                ForEach(IslandTab.allCases) { Text($0.title).tag($0.rawValue) }
            }
            ForEach(IslandTab.allCases) { tab in
                Toggle(tab.title, isOn: Binding(get: { !hidden.contains(tab.rawValue) }, set: { show in
                    var h = hidden
                    if show { h.remove(tab.rawValue) } else { h.insert(tab.rawValue) }
                    tabsHidden = h.sorted().joined(separator: ",")
                }))
            }
        }
        Section("Home cards") {
            ForEach(Array(cards.enumerated()), id: \.element) { i, id in
                HStack {
                    Text(HomeTab.all.first { $0.id == id }?.title ?? id)
                    Spacer()
                    Button { move(i, -1) } label: { Image(systemName: "arrow.up") }.disabled(i == 0)
                    Button { move(i, 1) } label: { Image(systemName: "arrow.down") }.disabled(i == cards.count - 1)
                    Button { var c = cards; c.remove(at: i); homeCards = c.joined(separator: ",") } label: { Image(systemName: "minus.circle") }
                }
                .buttonStyle(.borderless)
            }
            Menu("Add card") {
                ForEach(HomeTab.all.filter { !cards.contains($0.id) }, id: \.id) { card in
                    Button(card.title) { homeCards = (cards + [card.id]).joined(separator: ",") }
                }
            }
        }
    }

    private var hidden: Set<String> { Set(tabsHidden.split(separator: ",").map(String.init)) }
    private var cards: [String] { homeCards.split(separator: ",").map(String.init) }

    private func move(_ i: Int, _ d: Int) {
        var c = cards
        c.swapAt(i, i + d)
        homeCards = c.joined(separator: ",")
    }
}

private struct NowPlayingMoreSettings: View {
    @ObservedObject private var history = AppState.shared.history
    @AppStorage(Pref.nowPlayingIsland.rawValue) private var island = true
    @AppStorage(Pref.hideWhenPaused.rawValue) private var hideWhenPaused = true
    @AppStorage(Pref.announceTracks.rawValue) private var announce = false
    @AppStorage(Pref.mediaKeys.rawValue) private var mediaKeys = false
    @AppStorage(Pref.defaultPlayer.rawValue) private var player = "com.apple.Music"
    @AppStorage(Pref.marquee.rawValue) private var marquee = true
    @AppStorage(Pref.skipSeconds.rawValue) private var skip = 15
    @AppStorage(Pref.listeningHistory.rawValue) private var keepHistory = true
    @AppStorage(Pref.desktopLyrics.rawValue) private var desktopLyrics = false
    @AppStorage(Pref.squareArt.rawValue) private var squareArt = false

    var body: some View {
        Section("Island") {
            Toggle("Now Playing island", isOn: $island)
            Toggle("Hide when paused (after 30 s)", isOn: $hideWhenPaused)
            Toggle("Announce new tracks", isOn: $announce)
            Toggle("Scroll long titles", isOn: $marquee)
            Toggle("Square album art", isOn: $squareArt)
        }
        Section("Playback") {
            Toggle("Control playback with media keys (▶︎ ⏭ ⏮ go to the app Islet shows)", isOn: $mediaKeys)
            Picker("Play button opens", selection: $player) {
                Text("Music").tag("com.apple.Music"); Text("Spotify").tag("com.spotify.client"); Text("Kaset").tag("com.sertacozercan.Kaset")
            }
            Picker("Skip back / forward", selection: $skip) { Text("10 s").tag(10); Text("15 s").tag(15); Text("30 s").tag(30) }
        }
        Section("Lyrics & history") {
            Toggle("Desktop lyrics (floating, karaoke)", isOn: $desktopLyrics)
            Toggle("Keep listening history", isOn: $keepHistory)
            Button("Clear history (\(history.entries.count) songs)") { history.clear() }
        }
    }
}

private struct DisplayMoreSettings: View {
    @ObservedObject private var tweaks = AppState.shared.displayTweaks
    @AppStorage(Pref.colorTemperature.rawValue) private var kelvin = 6500.0
    @AppStorage(Pref.cursorEffect.rawValue) private var cursor = "none"
    @State private var refresh: [CGDirectDisplayID: Double] = [:]

    var body: some View {
        Section("Software dimming (for monitors without DDC)") {
            ForEach(NSScreen.screens, id: \.localizedName) { screen in
                LabeledContent(screen.localizedName) {
                    Slider(value: Binding(get: { tweaks.dims[DisplayTweaks.key(screen)] ?? 0 }, set: { tweaks.dims[DisplayTweaks.key(screen)] = $0 }), in: 0...0.9)
                }
            }
        }
        Section("Colour temperature") {
            LabeledContent("Warmth") { Slider(value: $kelvin, in: 3400...9300, step: 100) { Text("\(Int(kelvin)) K") } }
            Button("Reset to 6500 K") { kelvin = 6500 }
        }
        Section("Refresh rate") {
            ForEach(NSScreen.screens, id: \.localizedName) { screen in
                if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                    let info = DisplayTweaks.refreshRates(id)
                    if info.options.count > 1 {
                        Picker(screen.localizedName, selection: Binding(get: { refresh[id] ?? info.current.rounded() }, set: { rate in
                            if let o = info.options.first(where: { $0.rate.rounded() == rate }) { DisplayTweaks.setRefresh(id, o); refresh[id] = rate }
                        })) {
                            ForEach(info.options, id: \.self) { Text("\(Int($0.rate.rounded())) Hz").tag($0.rate.rounded()) }
                        }
                    } else {
                        LabeledContent(screen.localizedName, value: "\(Int(info.current.rounded())) Hz")
                    }
                }
            }
        }
        Section("Screen light (for video calls)") {
            Toggle("Screen light", isOn: Binding(get: { AppState.shared.screenLight.on }, set: { AppState.shared.screenLight.set($0) }))
            LabeledContent("Brightness") { Slider(value: Binding(get: { Pref.screenLightBrightness.double }, set: { Pref.screenLightBrightness.set($0) }), in: 0.2...1) }
            LabeledContent("Warmth") { Slider(value: Binding(get: { Pref.screenLightWarmth.double }, set: { Pref.screenLightWarmth.set($0) }), in: 0...1) }
            LabeledContent("Width") { Slider(value: Binding(get: { Pref.screenLightWidth.double }, set: { Pref.screenLightWidth.set($0) }), in: 0.05...0.3) }
            Toggle("Turn on automatically while the camera is in use", isOn: Binding(get: { Pref.screenLightAuto.bool }, set: { Pref.screenLightAuto.set($0) }))
            Toggle("Light every display", isOn: Binding(get: { Pref.screenLightAllDisplays.bool }, set: { Pref.screenLightAllDisplays.set($0) }))
            Text("Toggle from Tools, the command palette (⌃⌥K), or /screen-light in the local API. It's hidden from screen sharing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Pointer") {
            Picker("Cursor effect", selection: $cursor) {
                Text("None").tag("none"); Text("Click ripples").tag("ripple"); Text("Halo").tag("halo"); Text("Ripples + spotlight").tag("spotlight")
            }
            Text("Hold ⌃⌥ to spotlight the pointer when an effect is on.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ClipboardSettings: View {
    @ObservedObject private var clipboard = AppState.shared.clipboard
    @AppStorage(Pref.clipLimit.rawValue) private var limit = 100
    @AppStorage(Pref.clipKeepAfterQuit.rawValue) private var keep = true
    @AppStorage(Pref.clipPaused.rawValue) private var paused = false
    @AppStorage(Pref.clipIgnore.rawValue) private var ignore = ""
    @AppStorage(Pref.clipSound.rawValue) private var sound = false
    @AppStorage(Pref.clipAutoClear.rawValue) private var autoClear = "never"
    @AppStorage(Pref.clipStripTracking.rawValue) private var strip = true
    @AppStorage(Pref.shelfCleanupDays.rawValue) private var cleanup = 0
    @AppStorage(Pref.shelfCopyFiles.rawValue) private var copies = false

    var body: some View {
        Section("Clipboard history") {
            Toggle("Pause capturing", isOn: $paused)
            Stepper("Keep \(limit) items", value: $limit, in: 10...1000, step: 10)
            Toggle("Keep history after quitting", isOn: $keep)
            Picker("Auto-clear", selection: $autoClear) {
                Text("Never").tag("never"); Text("After 1 hour").tag("1h"); Text("After 1 day").tag("1d")
                Text("When the Mac locks").tag("lock"); Text("On sleep or lock").tag("sleep")
            }
            Toggle("Remove tracking from copied links (utm_, fbclid…)", isOn: $strip)
            Toggle("Don't save API keys, tokens or private keys", isOn: Binding(get: { Pref.clipSkipSecrets.bool }, set: { Pref.clipSkipSecrets.set($0) }))
            Toggle("Play a sound on copy", isOn: $sound)
            Button("Clear history now", role: .destructive) { clipboard.clear() }
        }
        Section("Ignore copies from these apps") {
            TextField("Bundle IDs, comma separated", text: $ignore, axis: .vertical).lineLimit(2...4)
            if let front = NSWorkspace.shared.runningApplications.first(where: { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier })?.bundleIdentifier {
                Text("Example: \(front)").font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Shelf") {
            Toggle("Keep independent copies of shelved files", isOn: $copies)
            Picker("Clean up items after", selection: $cleanup) {
                Text("Never").tag(0); Text("1 day").tag(1); Text("3 days").tag(3); Text("1 week").tag(7); Text("1 month").tag(30)
            }
        }
    }
}

private struct FocusMoreSettings: View {
    @AppStorage(Pref.focusSound.rawValue) private var sound = "none"
    @AppStorage(Pref.focusSoundVolume.rawValue) private var volume = 0.4
    @AppStorage(Pref.focusSoundStopWithPomodoro.rawValue) private var stop = true
    @AppStorage(Pref.breakReminders.rawValue) private var breaks = false
    @AppStorage(Pref.menuBarTimer.rawValue) private var menuBarTimer = false

    var body: some View {
        Section("Focus sounds") {
            Picker("Sound", selection: $sound) { ForEach(FocusSoundsModel.kinds, id: \.0) { Text($0.1).tag($0.0) } }
            LabeledContent("Volume") { Slider(value: $volume, in: 0...1) }
            Toggle("Stop when a focus session ends", isOn: $stop)
        }
        Section("Breaks") {
            Toggle("20-20-20 reminders (every 20 minutes, look away for 20 seconds)", isOn: $breaks)
            Toggle("Show the timer in the menu bar", isOn: $menuBarTimer)
        }
    }
}

private struct WidgetMoreSettings: View {
    @AppStorage(Pref.worldClocks.rawValue) private var zones = ""
    @AppStorage(Pref.stockAlerts.rawValue) private var alerts = ""
    @AppStorage(Pref.meetingAlerts.rawValue) private var meetingAlerts = true
    @AppStorage(Pref.menuBarNextMeeting.rawValue) private var nextMeeting = false
    @AppStorage(Pref.searchEngines.rawValue) private var engines = ""

    var body: some View {
        Section("World clock") {
            TextField("Time zones, e.g. America/New_York, Europe/London, Asia/Tokyo", text: $zones)
        }
        Section("Stock alerts") {
            TextField("e.g. AAPL>250, NVDA<100", text: $alerts)
        }
        Section("Meetings") {
            Toggle("Full-screen alert a minute before meetings, with Join", isOn: $meetingAlerts)
            Toggle("Next meeting in the menu bar", isOn: $nextMeeting)
        }
        Section("Search engines (command palette: “g cats”)") {
            TextEditor(text: $engines).font(.system(size: 11, design: .monospaced)).frame(height: 90)
            Text("One per line: keyword=URL with %s for the query.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AskAISettings: View {
    @ObservedObject private var ai = AppState.shared.askAI
    @AppStorage(Pref.askAIModel.rawValue) private var model = "claude-sonnet-5-5"
    @State private var key = ""

    var body: some View {
        Section("Ask AI") {
            HStack {
                SecureField(ai.hasKey ? "API key saved in Keychain" : "Anthropic API key", text: $key)
                Button(ai.hasKey && key.isEmpty ? "Remove" : "Save") { ai.setKey(key); key = "" }
            }
            Picker("Model", selection: $model) {
                Text("Claude Sonnet 5.5").tag("claude-sonnet-5-5")
                Text("Claude Opus 5.5").tag("claude-opus-5-5")
                Text("Claude Haiku 5.5").tag("claude-haiku-5-5")
            }
            Text("Questions go straight from your Mac to Anthropic with your key; nothing else is sent.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct KeyboardMoreSettings: View {
    @AppStorage(Pref.typingSounds.rawValue) private var typing = false
    @AppStorage(Pref.typingSoundStyle.rawValue) private var style = "mechanical"

    var body: some View {
        Section("Typing") {
            Toggle("Typing sounds", isOn: $typing)
            Picker("Sound", selection: $style) { Text("Mechanical").tag("mechanical"); Text("Typewriter").tag("typewriter") }
            Text("Paste as plain text: ⌃⌥V · Launcher wheel: ⌃⌥W · Show island: ⌥Space").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ApprovalRulesSettings: View {
    @ObservedObject private var agents = AppState.shared.agents

    var body: some View {
        Section("Always allowed") {
            if agents.alwaysAllow.isEmpty { Text("None yet — use “Always” on an approval island.").font(.caption).foregroundStyle(.secondary) }
            ForEach(agents.alwaysAllow, id: \.self) { rule in
                HStack {
                    Text(rule.replacingOccurrences(of: "|", with: " → "))
                    Spacer()
                    Button("Revoke") { agents.alwaysAllow.removeAll { $0 == rule } }
                }
            }
        }
    }
}

private struct PetSettings: View {
    @ObservedObject private var pet = AppState.shared.pet
    @AppStorage(Pref.petEnabled.rawValue) private var enabled = true
    @AppStorage(Pref.petSpecies.rawValue) private var species = "🐱"
    @AppStorage(Pref.petName.rawValue) private var name = ""
    @AppStorage(Pref.petHue.rawValue) private var hue = 0.0
    @AppStorage(Pref.petSize.rawValue) private var size = 56.0
    @AppStorage(Pref.petPersonality.rawValue) private var personality = "playful"
    @AppStorage(Pref.petBedStart.rawValue) private var bedStart = 23
    @AppStorage(Pref.petBedEnd.rawValue) private var bedEnd = 7
    @AppStorage(Pref.petWindowRides.rawValue) private var windowRides = true
    @AppStorage(Pref.petSpeech.rawValue) private var speech = true
    @AppStorage(Pref.petWeatherOutfits.rawValue) private var weatherOutfits = true
    @AppStorage(Pref.petHolidayOutfits.rawValue) private var holidayOutfits = true
    @State private var confirmReset = false

    var body: some View {
        Section {
            Toggle("Show desk pet", isOn: $enabled)
            TextField("Name", text: $name, prompt: Text(PetCatalog.name(for: species)))
            Picker("Personality", selection: $personality) {
                ForEach(PetPersonality.allCases) { Text($0.title).tag($0.rawValue) }
            }
        }
        Section("Character") {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 13), spacing: 6) {
                ForEach(PetCatalog.species, id: \.emoji) { s in
                    Button { species = s.emoji } label: {
                        Text(s.emoji).font(.system(size: 22))
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(species == s.emoji ? Color.accentColor.opacity(0.35) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .help(s.name)
                }
            }
            LabeledContent("Fur colour") {
                HStack {
                    Text(species).hueRotation(.degrees(hue))
                    Slider(value: $hue, in: 0...360)
                    Button("Natural") { hue = 0 }
                }
            }
            LabeledContent("Size") { Slider(value: $size, in: 32...96, step: 4) { Text("\(Int(size)) pt") } }
        }
        Section("Life") {
            Picker("Bedtime", selection: $bedStart) { ForEach(0..<24, id: \.self) { Text(hour($0)).tag($0) } }
            Picker("Wakes up", selection: $bedEnd) { ForEach(0..<24, id: \.self) { Text(hour($0)).tag($0) } }
            Toggle("Ride on top of the front window", isOn: $windowRides)
            Toggle("Speech bubbles", isOn: $speech)
            Toggle("Dress for the weather", isOn: $weatherOutfits)
            Toggle("Holiday outfits", isOn: $holidayOutfits)
        }
        Section("Data") {
            LabeledContent("Together for", value: "\(pet.age) days · \(pet.data.memories.count) memories · \(pet.data.catches.values.reduce(0, +)) fish")
            HStack {
                Button("Back Up…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "\(pet.name) backup.json"
                    if panel.runModal() == .OK, let url = panel.url, let data = pet.exportData() { try? data.write(to: url) }
                }
                Button("Restore…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) { _ = pet.importData(data) }
                }
                Spacer()
                Button("Start Over…", role: .destructive) { confirmReset = true }
            }
            .confirmationDialog("Start over with a new pet?", isPresented: $confirmReset) {
                Button("Start Over", role: .destructive) { pet.reset() }
            } message: { Text("Stats, memories and the fish collection are cleared.") }
        }
    }

    private func hour(_ h: Int) -> String {
        Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!.formatted(date: .omitted, time: .shortened)
    }
}
