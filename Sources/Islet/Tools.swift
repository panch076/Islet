import AppKit
import AVFoundation
import SwiftUI
import Translation

// MARK: - Color eyedropper

enum Eyedropper {
    @MainActor
    static func pick() {
        NSColorSampler().show { color in
            guard let c = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            Task { @MainActor in AppState.shared.hud.show(icon: "eyedropper.halffull", text: "\(hex) copied") }
        }
    }
}

// MARK: - App launcher

@MainActor
final class LauncherModel: ObservableObject {
    struct App: Identifiable, Hashable {
        var id: String { url.path }
        let name: String
        let url: URL
    }

    @Published private(set) var all: [App] = []
    @Published var pinned: [String] = UserDefaults.standard.stringArray(forKey: "pinnedApps") ?? [] {
        didSet { UserDefaults.standard.set(pinned, forKey: "pinnedApps") }
    }

    func load() {
        guard all.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
            var apps: [App] = []
            for dir in dirs {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".app") {
                    apps.append(App(name: String(name.dropLast(4)), url: URL(fileURLWithPath: dir).appendingPathComponent(name)))
                }
            }
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor in self.all = apps }
        }
    }

    var pinnedApps: [App] { pinned.compactMap { path in all.first { $0.url.path == path } } }

    func togglePin(_ app: App) {
        if let i = pinned.firstIndex(of: app.url.path) { pinned.remove(at: i) } else { pinned.append(app.url.path) }
    }

    func launch(_ app: App) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: .init())
        NotchController.current?.collapse()
    }
}

// MARK: - Removable drives

@MainActor
final class DrivesModel: ObservableObject {
    struct Drive: Identifiable {
        var id: URL { url }
        let url: URL
        let name: String
        let free: Int64
        let total: Int64
    }

    @Published private(set) var drives: [Drive] = []
    private var observers: [Any] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, mounted) in [(NSWorkspace.didMountNotification, true), (NSWorkspace.didUnmountNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated {
                    let s = AppState.shared
                    s.drives.refresh()
                    if Pref.driveAlerts.bool, let url {
                        s.hud.show(icon: mounted ? "externaldrive.fill.badge.plus" : "externaldrive.badge.minus",
                                   text: "\(url.lastPathComponent) \(mounted ? "connected" : "ejected")", seconds: 2.5)
                    }
                }
            })
        }
        refresh()
    }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeNameKey,
                                      .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        drives = urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsEjectable == true || v.volumeIsRemovable == true || v.volumeIsInternal == false,
                  url.path != "/" else { return nil }
            return Drive(url: url, name: v.volumeName ?? url.lastPathComponent,
                         free: Int64(v.volumeAvailableCapacity ?? 0), total: Int64(v.volumeTotalCapacity ?? 0))
        }
    }

    func eject(_ drive: Drive) {
        DispatchQueue.global().async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: drive.url)
            } catch {
                Task { @MainActor in AppState.shared.hud.show(icon: "exclamationmark.triangle", text: "\(drive.name) is in use") }
            }
        }
    }

    func ejectAll() { drives.forEach(eject) }
}

// MARK: - Apple Shortcuts

@MainActor
final class ShortcutsModel: ObservableObject {
    @Published private(set) var names: [String] = []

    func load() {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["list"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
            Task { @MainActor in self.names = names }
        }
    }

    func run(_ name: String) {
        AppState.shared.hud.show(icon: "square.2.layers.3d", text: "Running \(name)…")
        DispatchQueue.global().async {
            let ok = FileTools.run("/usr/bin/shortcuts", ["run", name])
            Task { @MainActor in
                AppState.shared.hud.show(icon: ok ? "checkmark.circle.fill" : "exclamationmark.triangle", text: ok ? "\(name) done" : "\(name) failed")
            }
        }
    }
}

// MARK: - Screenshot shelf

/// Adds new screenshots to the shelf as they're taken.
@MainActor
final class ScreenshotWatcher {
    /// macOS tags its screenshots with an xattr regardless of the (localized) file name.
    static func isScreenCapture(_ url: URL) -> Bool {
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0 { return true }
        let name = url.lastPathComponent
        return name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot") || name.hasPrefix("Screen Recording")
    }

    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []

    var folder: URL {
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    func setEnabled(_ on: Bool) {
        source?.cancel()
        source = nil
        guard on else { return }
        let path = folder.path
        // Opening Desktop can show a permission prompt that blocks, so stay off the main thread.
        DispatchQueue.global(qos: .utility).async {
            let fd = open(path, O_EVTONLY)
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            Task { @MainActor in
                guard fd >= 0 else { return }
                guard self.source == nil, Pref.screenshotShelf.bool else { close(fd); return }
                self.known = names
                let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
                src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan(path) } }
                src.setCancelHandler { close(fd) }
                src.resume()
                self.source = src
            }
        }
    }

    private func scan(_ path: String) {
        let now = Set((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
        let added = now.subtracting(known)
        known = now
        for name in added where !name.hasPrefix(".") && Self.isScreenCapture(URL(fileURLWithPath: path).appendingPathComponent(name)) {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            AppState.shared.shelf.add(url)
            AppState.shared.hud.show(icon: "camera.viewfinder", text: "Screenshot added to Shelf")
        }
    }
}

// MARK: - Keystroke HUD & keyboard cleaning lock

@MainActor
final class KeyboardTools: ObservableObject {
    @Published private(set) var cleaningUntil: Date?
    private var keystrokeMonitor: Any?
    private var cleaningTap: CFMachPort?
    private var cleaningSource: CFRunLoopSource?
    fileprivate static var current: KeyboardTools?

    /// Shows pressed shortcuts in the island — handy for screen recordings and demos.
    func setKeystrokeHUD(_ on: Bool) {
        if let keystrokeMonitor { NSEvent.removeMonitor(keystrokeMonitor) }
        keystrokeMonitor = nil
        guard on else { return }
        keystrokeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let text = Self.describe(event)
            MainActor.assumeIsolated { AppState.shared.hud.show(icon: "keyboard", text: text, seconds: 1.2) }
        }
    }

    static func describe(_ e: NSEvent) -> String {
        var s = ""
        let f = e.modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑", 117: "⌦"]
        return s + (special[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "").uppercased())
    }

    /// Swallows all keyboard input so you can wipe the keyboard. Ends after `seconds` or from the island.
    func startCleaning(seconds: TimeInterval = 45) {
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
            AppState.shared.hud.show(icon: "lock.fill", text: "Allow Islet in Accessibility settings", seconds: 3)
            return
        }
        stopCleaning()
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue) | (1 << 14)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { if let t = KeyboardTools.current?.cleaningTap { CGEvent.tapEnable(tap: t, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            return nil
        }, userInfo: nil) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        cleaningTap = tap
        cleaningSource = source
        Self.current = self
        let until = Date().addingTimeInterval(seconds)
        cleaningUntil = until
        AppState.shared.hud.show(icon: "keyboard.badge.ellipsis", text: "Keyboard locked for cleaning", seconds: 2.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { if self?.cleaningUntil == until { self?.stopCleaning() } }
        }
    }

    func stopCleaning() {
        guard cleaningTap != nil else { return }
        if let cleaningTap {
            CGEvent.tapEnable(tap: cleaningTap, enable: false)
            CFMachPortInvalidate(cleaningTap)
        }
        if let cleaningSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), cleaningSource, .commonModes) }
        cleaningTap = nil
        cleaningSource = nil
        cleaningUntil = nil
        AppState.shared.hud.show(icon: "keyboard", text: "Keyboard unlocked")
    }
}

// MARK: - Teleprompter

@MainActor
final class TeleprompterModel: ObservableObject {
    @Published var text = UserDefaults.standard.string(forKey: "teleprompterText") ?? "" {
        didSet { UserDefaults.standard.set(text, forKey: "teleprompterText") }
    }
    @Published var speed = UserDefaults.standard.object(forKey: "teleprompterSpeed") as? Double ?? 30 {
        didSet { UserDefaults.standard.set(speed, forKey: "teleprompterSpeed") }
    }
    @Published var fontSize = 18.0
    @Published private(set) var playing = false
    @Published private(set) var startDate: Date?
    @Published private(set) var offset: Double = 0

    func toggle() {
        if let startDate {
            offset += Date().timeIntervalSince(startDate) * speed
            self.startDate = nil
            playing = false
        } else {
            startDate = Date()
            playing = true
        }
    }

    func reset() { startDate = playing ? Date() : nil; offset = 0 }

    func position(at date: Date) -> Double {
        offset + (startDate.map { date.timeIntervalSince($0) * speed } ?? 0)
    }
}

// MARK: - Camera mirror

final class CameraPreview: NSView {
    private let session = AVCaptureSession()
    /// Set on the session queue; checked there before starting.
    private final class Flag: @unchecked Sendable { var value = false }
    private let stopped = Flag()
    private let queue = DispatchQueue(label: "islet.mirror")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1)) // mirror
        layer = preview
        let session = self.session
        let queue = self.queue
        let stopped = self.stopped
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted, let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            queue.async {
                guard !stopped.value else { return }
                session.beginConfiguration()
                session.sessionPreset = .medium
                if session.canAddInput(input) { session.addInput(input) }
                session.commitConfiguration()
                session.startRunning()
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    func stop() {
        let session = self.session
        let stopped = self.stopped
        queue.async {
            stopped.value = true
            session.stopRunning()
        }
    }
}

struct CameraMirror: NSViewRepresentable {
    func makeNSView(context: Context) -> CameraPreview { CameraPreview(frame: .zero) }
    func updateNSView(_ nsView: CameraPreview, context: Context) {}
    static func dismantleNSView(_ nsView: CameraPreview, coordinator: ()) { nsView.stop() }
}

// MARK: - Tools tab

struct ToolsTab: View {
    enum Section: String, CaseIterable { case apps = "Apps", tools = "Tools", shortcuts = "Shortcuts", ports = "Ports", prompter = "Prompter", mirror = "Mirror" }
    @AppStorage("toolsSection") private var section: Section = .tools

    var body: some View {
        VStack(spacing: Layout.gap) {
            Picker("", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Group {
                switch section {
                case .apps: LauncherView()
                case .tools: QuickToolsView()
                case .shortcuts: ShortcutsView()
                case .ports: PortsView().padding(Layout.card).background(cardBackground)
                case .prompter: TeleprompterView()
                case .mirror:
                    CameraMirror()
                        .clipShape(RoundedRectangle(cornerRadius: Layout.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Layout.radius).strokeBorder(.white.opacity(0.15)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct LauncherView: View {
    @ObservedObject private var model = AppState.shared.launcher
    @State private var query = ""

    private var results: [LauncherModel.App] {
        query.isEmpty ? model.pinnedApps : model.all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $query).textFieldStyle(.plain)
                    .onSubmit { if let first = results.first { model.launch(first) } }
            }
            .padding(7).background(cardBackground)
            if results.isEmpty {
                Text(query.isEmpty ? "Search for an app, then right-click to pin it here" : "No apps found")
                    .font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(results.prefix(30)) { app in AppIcon(app: app) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear { model.load() }
    }
}

private struct AppIcon: View {
    let app: LauncherModel.App
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 48, height: 48)
                .scaleEffect(hovering ? 1.06 : 1)
                .animation(Motion.standard, value: hovering)
            Text(app.name).font(.system(size: 10)).lineLimit(1)
        }
        .frame(width: 70)
        .onHover { hovering = $0 }
        .onTapGesture { AppState.shared.launcher.launch(app) }
        .contextMenu {
            Button(AppState.shared.launcher.pinned.contains(app.url.path) ? "Unpin" : "Pin") { AppState.shared.launcher.togglePin(app) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
        }
    }
}

private struct QuickToolsView: View {
    @ObservedObject private var drives = AppState.shared.drives
    @ObservedObject private var keyboard = AppState.shared.keyboardTools
    @State private var translateText = ""
    @State private var showTranslation = false

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        HStack(alignment: .top, spacing: Layout.gap) {
            VStack(spacing: 8) {
                LazyVGrid(columns: columns, spacing: 8) {
                    tool("eyedropper.halffull", "Pick color") { NotchController.current?.collapse(); Eyedropper.pick() }
                    tool("camera.viewfinder", "Capture") { NotchController.current?.collapse(); ScreenCapture.capture(.selectionToClipboard) }
                    tool("keyboard.badge.ellipsis", keyboard.cleaningUntil == nil ? "Clean keys" : "Unlock keys") {
                        keyboard.cleaningUntil == nil ? keyboard.startCleaning() : keyboard.stopCleaning()
                    }
                    tool("sparkles.tv", "Clean screen") { NotchController.current?.collapse(); CleanScreen.start() }
                    tool("doc.plaintext", "Paste plain") { NotchController.current?.collapse(); PastePlain.paste() }
                    tool("circle.circle", "Launcher") { NotchController.current?.collapse(); LauncherWheel.shared.toggle() }
                    tool("light.max", AppState.shared.screenLight.on ? "Light off" : "Screen light") { AppState.shared.screenLight.toggle() }
                }
                HStack(spacing: 6) {
                    Image(systemName: "translate").foregroundStyle(.secondary)
                    TextField("Translate…", text: $translateText).textFieldStyle(.plain)
                        .onSubmit { showTranslation = !translateText.isEmpty }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(cardBackground)
                .translationPresentation(isPresented: $showTranslation, text: translateText)
            }
            .frame(width: 260)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Drives").font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    if drives.drives.count > 1 {
                        Button("Eject All", action: drives.ejectAll).buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if drives.drives.isEmpty {
                    Text("No external drives").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(drives.drives) { d in
                                HStack(spacing: 8) {
                                    Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(d.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text("\(ByteCountFormatter.string(fromByteCount: d.free, countStyle: .file)) free")
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    Button { drives.eject(d) } label: { Image(systemName: "eject.fill").font(.system(size: 10)) }
                                        .buttonStyle(BouncyButtonStyle()).help("Eject \(d.name)")
                                }
                            }
                        }
                        .padding(.trailing, 6)
                    }
                    .scrollIndicators(.never)
                }
            }
            .padding(Layout.card)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(cardBackground)
        }
        .font(.system(size: 12))
    }

    private func tool(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).frame(width: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(cardBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(BouncyButtonStyle())
    }
}

private struct ShortcutsView: View {
    @ObservedObject private var model = AppState.shared.shortcuts

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                ForEach(model.names, id: \.self) { name in
                    BouncyButton { model.run(name) } label: {
                        Label(name, systemImage: "square.2.layers.3d").lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    .adaptiveGlass(.clear.interactive(), in: .capsule)
                }
            }
            if model.names.isEmpty {
                Text("No shortcuts found. Create some in the Shortcuts app.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .onAppear { model.load() }
    }
}

private struct TeleprompterView: View {
    @ObservedObject private var model = AppState.shared.teleprompter
    @State private var editing = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if editing || model.text.isEmpty {
                    TextEditor(text: $model.text).font(.system(size: 12)).scrollContentBackground(.hidden)
                } else {
                    // Scrolls text up past a reading line near the camera.
                    TimelineView(.animation(paused: !model.playing)) { ctx in
                        GeometryReader { geo in
                            Text(model.text)
                                .font(.system(size: model.fontSize, weight: .semibold))
                                .frame(width: geo.size.width, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .offset(y: 20 - model.position(at: ctx.date))
                        }
                        .clipped()
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                                     .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                    }
                }
            }
            .padding(8)
            .background(cardBackground)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    BouncyButton(action: model.toggle) {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 30, height: 30)
                    }
                    .adaptiveGlass(.clear.interactive(), in: .circle)
                    .disabled(model.text.isEmpty)
                    BouncyButton(action: model.reset) { Image(systemName: "backward.end.fill").frame(width: 30, height: 30) }
                        .adaptiveGlass(.clear.interactive(), in: .circle)
                }
                Toggle("Edit", isOn: $editing).toggleStyle(.button).controlSize(.small)
                Label("Speed", systemImage: "hare").labelStyle(.iconOnly).font(.caption).foregroundStyle(.secondary)
                Slider(value: $model.speed, in: 5...120).frame(width: 70).controlSize(.mini).help("Speed")
                Slider(value: $model.fontSize, in: 12...36).frame(width: 70).controlSize(.mini).help("Text size")
            }
        }
    }
}
