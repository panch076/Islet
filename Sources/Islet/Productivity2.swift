import AppKit
import Carbon.HIToolbox
import EventKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Countdown timer (custom h/m/s, optional repeat)

@MainActor
final class CountdownModel: ObservableObject {
    @Published var hours = 0
    @Published var minutes = 5
    @Published var seconds = 0
    @Published var repeats = false
    @Published private(set) var endDate: Date?
    @Published private(set) var total: TimeInterval = 0

    var running: Bool { endDate != nil }

    func remaining(at date: Date = Date()) -> TimeInterval { endDate.map { max(0, $0.timeIntervalSince(date)) } ?? 0 }

    var display: String {
        let r = Int(ceil(remaining()))
        return r >= 3600 ? String(format: "%d:%02d:%02d", r / 3600, r % 3600 / 60, r % 60) : String(format: "%02d:%02d", r / 60, r % 60)
    }

    func start(_ duration: TimeInterval? = nil) {
        total = duration ?? TimeInterval(hours * 3600 + minutes * 60 + seconds)
        guard total > 0 else { return }
        endDate = Date().addingTimeInterval(total)
    }

    func cancel() { endDate = nil }

    func tick() {
        guard let endDate, Date() >= endDate else { return }
        NSSound(named: NSSound.Name(Pref.pomoSound.string))?.play()
        AppState.shared.hud.show(icon: "timer", text: "Timer done", seconds: 4)
        if repeats { self.endDate = Date().addingTimeInterval(total) } else { self.endDate = nil }
    }
}

// MARK: - 20-20-20 break reminders

@MainActor
final class BreakReminder {
    private var activeSince = Date()

    func tick() {
        guard Pref.breakReminders.bool else { activeSince = Date(); return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle > 120 { activeSince = Date(); return }
        if Date().timeIntervalSince(activeSince) >= 20 * 60 {
            activeSince = Date()
            NSSound(named: "Purr")?.play()
            AppState.shared.hud.show(icon: "eye", text: "Look 20 feet away for 20 seconds", seconds: 8)
        }
    }
}

// MARK: - Screen time (time per frontmost app)

@MainActor
final class ScreenTimeModel: ObservableObject {
    @Published private(set) var today: [String: Double] = [:]
    private var days: [String: [String: Double]] = (UserDefaults.standard.dictionary(forKey: "screenTime") as? [String: [String: Double]]) ?? [:]
    private var lastSave = Date()

    init() { today = days[PomodoroModel.dayKey(Date())] ?? [:] }

    /// Called every second; counts only while the user is active.
    func tick() {
        guard Pref.screenTime.bool, let app = NSWorkspace.shared.frontmostApplication?.localizedName else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 120 else { return }
        let key = PomodoroModel.dayKey(Date())
        days[key, default: [:]][app, default: 0] += 1
        today = days[key] ?? [:]
        if Date().timeIntervalSince(lastSave) > 60 {
            lastSave = Date()
            // Keep two weeks.
            let cutoff = PomodoroModel.dayKey(Date().addingTimeInterval(-14 * 86400))
            days = days.filter { $0.key >= cutoff }
            UserDefaults.standard.set(days, forKey: "screenTime")
        }
    }

    var week: [String: Double] {
        let keys = (0..<7).map { PomodoroModel.dayKey(Date().addingTimeInterval(-Double($0) * 86400)) }
        return keys.compactMap { days[$0] }.reduce(into: [:]) { acc, day in day.forEach { acc[$0.key, default: 0] += $0.value } }
    }

    static func format(_ s: Double) -> String {
        let m = Int(s) / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

// MARK: - Network data usage

@MainActor
final class DataUsageModel: ObservableObject {
    @Published private(set) var todayIn: UInt64 = 0
    @Published private(set) var todayOut: UInt64 = 0
    @Published private(set) var rateIn: Double = 0
    @Published private(set) var rateOut: Double = 0
    private var last: (UInt64, UInt64)?
    private var history: [String: [UInt64]] = (UserDefaults.standard.dictionary(forKey: "dataUsage") as? [String: [UInt64]]) ?? [:]
    private var ticks = 0

    init() {
        let t = history[PomodoroModel.dayKey(Date())] ?? [0, 0]
        todayIn = t[0]; todayOut = t.count > 1 ? t[1] : 0
    }

    func tick() {
        guard Pref.dataUsage.bool else { last = nil; return }
        let now = Self.counters()
        defer { last = now }
        guard let last, now.0 >= last.0, now.1 >= last.1 else { return }
        let dIn = now.0 - last.0, dOut = now.1 - last.1
        rateIn = Double(dIn); rateOut = Double(dOut)
        let key = PomodoroModel.dayKey(Date())
        var day = history[key] ?? [0, 0]
        day[0] += dIn; day[1] += dOut
        history[key] = day
        todayIn = day[0]; todayOut = day[1]
        ticks += 1
        if ticks % 60 == 0 {
            let cutoff = PomodoroModel.dayKey(Date().addingTimeInterval(-60 * 86400))
            history = history.filter { $0.key >= cutoff }
            UserDefaults.standard.set(history, forKey: "dataUsage")
        }
    }

    func total(days: Int) -> (UInt64, UInt64) {
        var down: UInt64 = 0, up: UInt64 = 0
        for offset in 0..<days {
            guard let day = history[PomodoroModel.dayKey(Date().addingTimeInterval(-Double(offset) * 86400))], !day.isEmpty else { continue }
            down += day[0]
            if day.count > 1 { up += day[1] }
        }
        return (down, up)
    }

    /// Bytes in/out across physical interfaces (en*), from the kernel's interface counters.
    private static func counters() -> (UInt64, UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            if let addr = a.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               String(cString: a.pointee.ifa_name).hasPrefix("en"),
               let data = a.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx += UInt64(data.pointee.ifi_ibytes)
                tx += UInt64(data.pointee.ifi_obytes)
            }
            p = a.pointee.ifa_next
        }
        return (rx, tx)
    }
}

// MARK: - Top processes & listening ports

enum ProcessTools {
    struct Proc: Identifiable { var id: Int32 { pid }; let pid: Int32; let cpu: Double; let name: String }
    struct Port: Identifiable { var id: String { "\(pid):\(port)" }; let pid: Int32; let command: String; let port: String }

    static func top(_ count: Int = 5) -> [Proc] {
        guard let out = run("/bin/ps", ["-Aceo", "pid=,pcpu=,comm=", "-r"]) else { return [] }
        return out.split(separator: "\n").prefix(count).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let cpu = Double(parts[1]) else { return nil }
            return Proc(pid: pid, cpu: cpu, name: String(parts[2]))
        }
    }

    static func listeningPorts() -> [Port] {
        guard let out = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]) else { return [] }
        var ports: [Port] = []
        var pid: Int32 = 0, command = ""
        for line in out.split(separator: "\n") {
            switch line.first {
            case "p": pid = Int32(line.dropFirst()) ?? 0
            case "c": command = String(line.dropFirst())
            case "n":
                let port = String(line.split(separator: ":").last ?? "")
                if !ports.contains(where: { $0.pid == pid && $0.port == port }) { ports.append(Port(pid: pid, command: command, port: port)) }
            default: break
            }
        }
        return ports.sorted { (Int($0.port) ?? 0) < (Int($1.port) ?? 0) }
    }

    static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

struct PortsView: View {
    @State private var ports: [ProcessTools.Port] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Listening ports").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ports) { p in
                        HStack {
                            Text(":\(p.port)").font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(width: 64, alignment: .leading)
                            Text(p.command).lineLimit(1)
                            Text("\(p.pid)").foregroundStyle(.secondary)
                            Spacer()
                            Button("Free") {
                                kill(p.pid, SIGTERM)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { reload() }
                            }
                            .controlSize(.small)
                        }
                        .font(.system(size: 11))
                    }
                    if ports.isEmpty { Text("Nothing is listening").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        DispatchQueue.global().async {
            let p = ProcessTools.listeningPorts()
            Task { @MainActor in ports = p }
        }
    }
}

// MARK: - Image compressor (target size)

extension FileTools {
    /// Re-encodes as JPEG, lowering quality (then size) until the file fits `bytes`.
    static func compress(_ url: URL, to bytes: Int) -> URL? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let dest = unique(url.deletingPathExtension().appendingPathExtension("compressed.jpg"))
        func encode(_ img: CGImage, _ q: Double) -> Data? {
            let data = NSMutableData()
            guard let d = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            return CGImageDestinationFinalize(d) ? data as Data : nil
        }
        for _ in 0..<6 {
            var lo = 0.05, hi = 0.95
            var best: Data?
            for _ in 0..<7 {
                let mid = (lo + hi) / 2
                guard let data = encode(image, mid) else { return nil }
                if data.count <= bytes { best = data; lo = mid } else { hi = mid }
            }
            if let best { return (try? best.write(to: dest)) != nil ? dest : nil }
            // Even the lowest quality is too big: shrink the image and try again.
            let w = Int(Double(image.width) * 0.75), h = Int(Double(image.height) * 0.75)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let smaller = ctx.makeImage() else { return nil }
            image = smaller
        }
        return nil
    }
}

// MARK: - Menu bar: timer and next meeting

@MainActor
final class MenuBarStatus {
    private var timerItem: NSStatusItem?
    private var meetingItem: NSStatusItem?

    func tick() {
        let s = AppState.shared
        // Timer: shown only while something is counting down.
        let countdown = s.pomodoro.running ? s.pomodoro.display : s.countdown.running ? s.countdown.display : nil
        if Pref.menuBarTimer.bool, let countdown {
            if timerItem == nil {
                timerItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                timerItem?.button?.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
                timerItem?.button?.imagePosition = .imageLeading
            }
            timerItem?.button?.title = " " + countdown
        } else if let t = timerItem {
            NSStatusBar.system.removeStatusItem(t)
            timerItem = nil
        }
        // Next meeting today.
        if Pref.menuBarNextMeeting.bool, let next = s.calendar.events.first(where: { !$0.allDay && $0.start > Date() }) {
            if meetingItem == nil {
                meetingItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            }
            let mins = Int(next.start.timeIntervalSinceNow / 60)
            meetingItem?.button?.title = "\(next.title.prefix(18)) in \(mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m")"
        } else if let m = meetingItem {
            NSStatusBar.system.removeStatusItem(m)
            meetingItem = nil
        }
    }
}

// MARK: - Meetings: countdown, join links, full-screen alert

enum MeetingLinks {
    private static let pattern = try! NSRegularExpression(
        pattern: #"https://[^\s<>"]*(zoom\.us/j/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join|webex\.com/|whereby\.com/|facetime\.apple\.com/)[^\s<>"]*"#)

    static func find(in texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) {
            let ns = text as NSString
            if let m = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                return URL(string: ns.substring(with: m.range))
            }
        }
        return nil
    }
}

@MainActor
final class MeetingAlerts {
    private var alerted: Set<String> = []
    private var window: NSWindow?

    func tick() {
        guard Pref.meetingAlerts.bool else { return }
        if alerted.count > 200 { alerted.removeAll() }
        for e in AppState.shared.calendar.events where !e.allDay {
            let lead = e.start.timeIntervalSinceNow
            // Recurring events share an id, so key by occurrence (id + start time).
            guard lead > 0, lead <= 60, alerted.insert("\(e.id)|\(e.start.timeIntervalSince1970)").inserted else { continue }
            show(e)
        }
    }

    private func show(_ e: CalendarModel.Event) {
        dismiss() // one alert at a time; never orphan an overlay
        NSSound(named: "Glass")?.play()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.45)
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: MeetingAlertView(event: e) { [weak self] in self?.dismiss() })
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; w.animator().alphaValue = 1 }
        window = w
    }

    func dismiss() {
        guard let w = window else { return }
        window = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; w.animator().alphaValue = 0 }) {
            Task { @MainActor in w.orderOut(nil) }
        }
    }
}

private struct MeetingAlertView: View {
    let event: CalendarModel.Event
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 40)).foregroundStyle(Color(nsColor: event.color))
            Text(event.title).font(.system(size: 26, weight: .bold))
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let s = max(0, Int(event.start.timeIntervalSinceNow))
                Text(s > 0 ? "Starts in \(s)s" : "Starting now").font(.title3).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 12) {
                if let url = event.joinURL {
                    Button { NSWorkspace.shared.open(url); dismiss() } label: {
                        Label("Join Meeting", systemImage: "video.fill").padding(.horizontal, 18).padding(.vertical, 8)
                    }
                    .adaptiveGlass(GlassSpec.regular.tint(.green.opacity(0.6)).interactive(), in: .capsule)
                }
                Button(action: dismiss) { Text("Dismiss").padding(.horizontal, 18).padding(.vertical, 8) }
                    .adaptiveGlass(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(36)
        .adaptiveGlass(.regular, in: .rect(cornerRadius: 30, style: .continuous))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Listening history & track announcements

@MainActor
final class ListeningHistory: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable { var id: Date { date }; let title: String; let artist: String; let date: Date }
    @Published private(set) var entries: [Entry] = []
    private var lastTrack: String?
    private(set) var lastPlaying = Date.distantPast

    init() {
        if let data = UserDefaults.standard.data(forKey: "listeningHistory"),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) { entries = saved }
    }

    func tick() {
        let player = NowPlayingModel.shared
        if player.isPlaying { lastPlaying = Date() }
        guard player.isPlaying, let track = player.track, track.id != lastTrack else { return }
        lastTrack = track.id
        if Pref.announceTracks.bool {
            AppState.shared.hud.show(icon: "music.note", text: "\(track.title) — \(track.artist)", seconds: 3)
        }
        guard Pref.listeningHistory.bool else { return }
        entries.insert(Entry(title: track.title, artist: track.artist, date: Date()), at: 0)
        entries = Array(entries.prefix(300))
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: "listeningHistory")
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: "listeningHistory")
    }
}

// MARK: - Stock price alerts ("AAPL>200, MSFT<300")

@MainActor
enum StockAlerts {
    private static var fired: Set<String> = []

    static func check(_ quotes: [StocksModel.Quote]) {
        let day = PomodoroModel.dayKey(Date())
        for rule in Pref.stockAlerts.string.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).uppercased() }) {
            let above = rule.contains(">")
            let parts = rule.split(whereSeparator: { $0 == ">" || $0 == "<" })
            guard parts.count == 2, let target = Double(parts[1]),
                  let q = quotes.first(where: { $0.symbol == String(parts[0]) }) else { continue }
            if (above ? q.price > target : q.price < target), fired.insert("\(rule)-\(day)").inserted {
                AppState.shared.hud.show(icon: above ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis",
                                         text: "\(q.symbol) \(above ? "above" : "below") \(target) · \(String(format: "%.2f", q.price))", seconds: 5)
            }
        }
    }
}

// MARK: - Quick search engines ("g cats", "yt lofi")

enum SearchEngines {
    /// Characters allowed in a query value: & + = ? # would otherwise split or alter the query.
    static let queryValue: CharacterSet = {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "&+=?#")
        return cs
    }()

    static var all: [(key: String, url: String)] {
        Pref.searchEngines.string.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]).trimmingCharacters(in: .whitespaces), String(parts[1])) : nil
        }
    }

    static func url(for query: String) -> (name: String, url: URL)? {
        let parts = query.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let engine = all.first(where: { $0.key == String(parts[0]) }),
              let q = String(parts[1]).addingPercentEncoding(withAllowedCharacters: SearchEngines.queryValue),
              let url = URL(string: engine.url.replacingOccurrences(of: "%s", with: q)) else { return nil }
        return (URL(string: engine.url)?.host ?? engine.key, url)
    }
}

// MARK: - Paste as plain text (⌃⌥V)

@MainActor
enum PastePlain {
    static func paste() {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string) else { return }
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
            AppState.shared.hud.show(icon: "lock.fill", text: "Allow Islet in Accessibility settings", seconds: 3)
            return
        }
        // Save every representation so the original clipboard can be restored afterwards.
        let saved = pb.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
        } ?? []
        pb.clearContents()
        pb.setString(text, forType: .string)
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pb.clearContents()
            pb.writeObjects(saved.map { reps in
                let item = NSPasteboardItem()
                reps.forEach { item.setData($0.value, forType: $0.key) }
                return item
            })
        }
    }
}

// MARK: - Settings backup

@MainActor
enum SettingsBackup {
    static func export() {
        guard let id = Bundle.main.bundleIdentifier, let domain = UserDefaults.standard.persistentDomain(forName: id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Islet Settings.plist"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0) else { return }
        try? data.write(to: url)
    }

    static func `import`() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle.main.bundleIdentifier,
              let data = try? Data(contentsOf: url),
              let domain = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        UserDefaults.standard.setPersistentDomain(domain, forName: id)
        AppState.shared.hud.show(icon: "checkmark.circle.fill", text: "Settings imported — restart Islet to apply everything", seconds: 4)
    }
}

// MARK: - Launcher wheel (⌃⌥L)

@MainActor
final class LauncherWheel {
    static let shared = LauncherWheel()
    private var panel: NSPanel?
    private var monitor: Any?

    func toggle() {
        if panel != nil { close(); return }
        let launcher = AppState.shared.launcher
        launcher.load()
        let size: CGFloat = 300
        let mouse = NSEvent.mouseLocation
        let p = NSPanel(contentRect: NSRect(x: mouse.x - size / 2, y: mouse.y - size / 2, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .popUpMenu
        p.contentView = NSHostingView(rootView: LauncherWheelView { [weak self] in self?.close() })
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        panel = p
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 }) {
            Task { @MainActor in p.orderOut(nil) }
        }
    }
}

private struct LauncherWheelView: View {
    @ObservedObject private var launcher = AppState.shared.launcher
    let close: () -> Void
    @State private var appeared = false

    var body: some View {
        let apps = Array(launcher.pinnedApps.prefix(10))
        ZStack {
            Circle().fill(.clear).adaptiveGlass(.regular, in: .circle).frame(width: 290, height: 290)
            if apps.isEmpty {
                Text("Pin apps in the Tools tab").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(apps.enumerated()), id: \.element.id) { i, app in
                let angle = Double(i) / Double(max(apps.count, 1)) * 2 * .pi - .pi / 2
                Button {
                    launcher.launch(app)
                    close()
                } label: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 52, height: 52)
                }
                .buttonStyle(BouncyButtonStyle())
                .help(app.name)
                .offset(x: appeared ? cos(angle) * 105 : 0, y: appeared ? sin(angle) * 105 : 0)
                .opacity(appeared ? 1 : 0)
            }
        }
        .frame(width: 300, height: 300)
        .onAppear { withAnimation(Motion.open) { appeared = true } }
    }
}

// MARK: - Desktop lyrics (floating, karaoke)

@MainActor
final class DesktopLyrics {
    private var panel: NSPanel?

    func apply() {
        guard Pref.desktopLyrics.bool else { panel?.orderOut(nil); panel = nil; return }
        guard panel == nil else { return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let p = NSPanel(contentRect: NSRect(x: screen.visibleFrame.midX - 380, y: screen.visibleFrame.minY + 80, width: 760, height: 132),
                        styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.contentView = NSHostingView(rootView: DesktopLyricsView().environment(NowPlayingModel.shared))
        p.minSize = NSSize(width: 480, height: 124)
        p.setFrameAutosaveName("IsletDesktopLyricsV2")
        p.orderFrontRegardless()
        panel = p
    }
}

private struct DesktopLyricsView: View {
    private var model: NowPlayingModel { .shared }
    @AppStorage(Prefs.syncOffset) private var syncOffset = 0.0
    @AppStorage(Prefs.karaokeSweep) private var karaoke = true
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            ArtworkView(image: model.artwork, cornerRadius: Pref.squareArt.bool ? 4 : 14, palette: model.palette)
                .frame(width: 84, height: 84)
                .shadow(color: model.accent.opacity(0.45), radius: 12, y: 4)
                .id(model.track?.id)
                .transition(.blurReplace)

            VStack(alignment: .leading, spacing: 4) {
                if let track = model.track {
                    HStack(spacing: 6) {
                        if let source = model.source {
                            Image(systemName: source.symbol).font(.system(size: 10, weight: .bold))
                        }
                        Text(track.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                        Text("—").opacity(0.5)
                        Text(track.artist).font(.system(size: 13, weight: .medium)).opacity(0.7).lineLimit(1)
                    }
                    .font(.system(size: 13))
                }
                lyrics
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hovering && model.canControl {
                CompactTransport()
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .adaptiveGlass(GlassSpec.regular.tint(model.accent.opacity(0.35)), in: .rect(cornerRadius: 28, style: .continuous))
        .environment(\.colorScheme, .dark)
        .onHover { h in withAnimation(Motion.standard) { hovering = h } }
        .animation(Motion.standard, value: model.track?.id)
        .padding(6)
    }

    /// The current line sweeping in as it's sung, with the next line beneath it.
    private var lyrics: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !model.isPlaying)) { ctx in
            let time = model.time(at: ctx.date) + syncOffset
            VStack(alignment: .leading, spacing: 4) {
                if let lines = model.lyrics.syncedLines {
                    let i = lines.activeIndex(at: time)
                    Group {
                        if let i, !lines[i].isGap {
                            let text = Text(lines[i].text).font(.system(size: 22, weight: .bold))
                            if karaoke {
                                text.textRenderer(KaraokeRenderer(progress: lines.sweepProgress(at: i, time: time), litOpacity: 1, dimOpacity: 0.35, feather: 20))
                            } else {
                                text
                            }
                        } else {
                            InstrumentalDots(size: 8).frame(height: 28)
                        }
                    }
                    .id(i ?? -1)
                    .transition(.opacity.combined(with: .offset(y: 8)))
                    let next = (i ?? -1) + 1
                    Text(next < lines.count ? lines[next].text : " ")
                        .font(.system(size: 15, weight: .semibold)).opacity(0.45)
                        .id("next\(next)")
                        .transition(.opacity)
                } else {
                    Text(model.track == nil ? "Play something to see lyrics" : model.lyrics == .loading ? "Finding lyrics…" : "No synced lyrics for this song")
                        .font(.system(size: 15, weight: .semibold)).opacity(0.6)
                }
            }
            .lineLimit(1)
            .animation(Motion.standard, value: model.lyrics.syncedLines?.activeIndex(at: time))
        }
    }
}
