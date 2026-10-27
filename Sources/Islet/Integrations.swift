import Accelerate
import AppKit
import AVFoundation
import Combine
import IOKit
import ScreenCaptureKit
import SQLite3
import SwiftUI

// MARK: - Message island & notification mirror (both read macOS databases; need Full Disk Access)

@MainActor
final class SystemFeeds: ObservableObject {
    @Published private(set) var messagesAccessible = true
    @Published private(set) var notificationsAccessible = true
    private var lastMessage: Int64 = -1
    private var lastNotification: Int64 = -1
    private var polling = false

    nonisolated private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    nonisolated private static let messagesDB = home + "/Library/Messages/chat.db"
    nonisolated private static let notificationsDB = home + "/Library/Group Containers/group.com.apple.usernoted/db2/db"

    func poll() {
        let wantMessages = Pref.messageIsland.bool, wantNotifications = Pref.notificationMirror.bool
        guard !polling, wantMessages || wantNotifications else { return }
        polling = true
        let (lm, ln) = (lastMessage, lastNotification)
        DispatchQueue.global(qos: .utility).async {
            let messages = wantMessages ? Self.newMessages(after: lm) : nil
            let notes = wantNotifications ? Self.newNotifications(after: ln) : nil
            Task { @MainActor in
                self.polling = false
                if wantMessages {
                    if self.messagesAccessible != (messages != nil) { self.messagesAccessible = messages != nil }
                    if let (maxID, items) = messages {
                        self.lastMessage = maxID
                        for m in items.suffix(2) {
                            AppState.shared.hud.show(icon: "message.fill", text: "\(m.sender): \(m.text)", seconds: 5, app: "com.apple.MobileSMS")
                        }
                    }
                }
                if wantNotifications {
                    if self.notificationsAccessible != (notes != nil) { self.notificationsAccessible = notes != nil }
                    if let (maxID, items) = notes {
                        self.lastNotification = maxID
                        for n in items.suffix(2) where !(wantMessages && n.app == "com.apple.MobileSMS") {
                            AppState.shared.hud.show(icon: "bell.fill", text: n.text, seconds: 5, app: n.app)
                        }
                    }
                }
            }
        }
    }

    // Returns nil when the database can't be opened (no Full Disk Access).
    nonisolated private static func newMessages(after: Int64) -> (Int64, [(sender: String, text: String)])? {
        query(messagesDB, after: after,
              maxSQL: "SELECT MAX(ROWID) FROM message",
              sql: """
              SELECT m.ROWID, m.text, m.attributedBody, IFNULL(h.id, '') FROM message m
              LEFT JOIN handle h ON m.handle_id = h.ROWID
              WHERE m.ROWID > ? AND m.is_from_me = 0 ORDER BY m.ROWID LIMIT 20
              """) { stmt in
            var text = column(stmt, 1) ?? ""
            if text.isEmpty, let blob = blob(stmt, 2) { text = attributedBodyText(blob) ?? "" }
            guard !text.isEmpty else { return nil }
            return (column(stmt, 3) ?? "Message", text)
        }
    }

    nonisolated private static func newNotifications(after: Int64) -> (Int64, [(app: String, text: String)])? {
        query(notificationsDB, after: after,
              maxSQL: "SELECT MAX(rec_id) FROM record",
              sql: "SELECT r.rec_id, a.identifier, r.data FROM record r JOIN app a ON r.app_id = a.app_id WHERE r.rec_id > ? ORDER BY r.rec_id LIMIT 20") { stmt in
            guard let app = column(stmt, 1), let data = blob(stmt, 2),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let req = plist["req"] as? [String: Any] else { return nil }
            let parts = [req["titl"], req["subt"], req["body"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
            guard !parts.isEmpty, app != Bundle.main.bundleIdentifier else { return nil }
            return (app, parts.joined(separator: " · "))
        }
    }

    /// On first call (`after` < 0) just records the newest row so old items aren't replayed.
    nonisolated private static func query<T>(_ path: String, after: Int64, maxSQL: String, sql: String,
                                             row: (OpaquePointer) -> T?) -> (Int64, [T])? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        if after < 0 {
            guard sqlite3_prepare_v2(db, maxSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            return (sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0, [])
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, after)
        var maxID = after
        var items: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            maxID = max(maxID, sqlite3_column_int64(stmt, 0))
            if let item = row(stmt) { items.append(item) }
        }
        return (maxID, items)
    }

    nonisolated private static func column(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(stmt, i).map { String(cString: $0) }
    }

    nonisolated private static func blob(_ stmt: OpaquePointer, _ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }

    /// Newer Messages stores text only in a typedstream NSAttributedString; pull the string out of it.
    nonisolated static func attributedBodyText(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let marker = data.range(of: Data("NSString".utf8)) else { return nil }
        var i = marker.upperBound + 5 // skip class info bytes
        guard i < bytes.count else { return nil }
        var length = Int(bytes[i])
        i += 1
        if length == 0x81, i + 1 < bytes.count {
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            i += 2
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<(i + length)], encoding: .utf8)
    }
}

// MARK: - Shell activity (zsh hooks call the local API)

@MainActor
final class ShellModel: ObservableObject {
    struct Command: Identifiable, Equatable { let id: String; let command: String; let started: Date }
    @Published private(set) var running: [String: Command] = [:]

    /// The longest-running command that's been going for a few seconds.
    var visible: Command? {
        running.values.filter { Date().timeIntervalSince($0.started) > 3 }.min { $0.started < $1.started }
    }

    func start(id: String, command: String) {
        running[id] = Command(id: id, command: String(command.prefix(60)), started: Date())
    }

    func end(id: String, code: Int) {
        guard let c = running.removeValue(forKey: id) else { return }
        let took = Date().timeIntervalSince(c.started)
        guard took > 10 else { return }
        NSSound(named: code == 0 ? "Glass" : "Basso")?.play()
        AppState.shared.hud.show(icon: code == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill",
                                 text: "\(c.command.split(separator: " ").first ?? "") \(code == 0 ? "done" : "failed (\(code))") · \(CallModel.duration(since: c.started))",
                                 seconds: 4)
    }

    static let zshSnippet = """
    # Islet shell activity — add to ~/.zshrc
    islet_preexec() { ISLET_CMD=1; curl -s -m 1 -G http://127.0.0.1:47219/shell --data-urlencode state=start --data-urlencode id=$$ --data-urlencode "cmd=$1" >/dev/null 2>&1 &! }
    islet_precmd() { local c=$?; [ -n "$ISLET_CMD" ] && curl -s -m 1 -G http://127.0.0.1:47219/shell --data-urlencode state=end --data-urlencode id=$$ --data-urlencode code=$c >/dev/null 2>&1 &!; ISLET_CMD= }
    autoload -Uz add-zsh-hook; add-zsh-hook preexec islet_preexec; add-zsh-hook precmd islet_precmd
    """
}

// MARK: - Mouse / keyboard / trackpad batteries

enum PeripheralBatteries {
    struct Device: Identifiable, Equatable { var id: String { name }; let name: String; let percent: Int }

    static func read() -> [Device] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [Device] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int,
                  let name = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  !out.contains(where: { $0.name == name }) else { continue }
            out.append(Device(name: name, percent: percent))
        }
        return out
    }
}

// MARK: - Clipboard smart actions

enum SmartActions {
    struct Action: Identifiable { var id: String { title }; let title: String; let icon: String; let run: () -> Void }

    @MainActor
    static func actions(for text: String) -> [Action] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [Action] = []
        if let url = URL(string: t), let scheme = url.scheme, ["http", "https"].contains(scheme) {
            out.append(Action(title: "Open Link", icon: "safari") { NSWorkspace.shared.open(url) })
        }
        if t.range(of: #"^[^@\s]+@[^@\s]+\.[a-z]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil,
           let url = URL(string: "mailto:\(t)") {
            out.append(Action(title: "Compose Email", icon: "envelope") { NSWorkspace.shared.open(url) })
        }
        if t.range(of: #"^\+?[\d\s\-().]{7,}$"#, options: .regularExpression) != nil,
           let url = URL(string: "tel:\(t.filter { $0.isNumber || $0 == "+" })") {
            out.append(Action(title: "Call", icon: "phone") { NSWorkspace.shared.open(url) })
        }
        if let rgb = hexColor(t) {
            out.append(Action(title: "Copy as rgb(\(rgb.0), \(rgb.1), \(rgb.2))", icon: "paintpalette") {
                copy("rgb(\(rgb.0), \(rgb.1), \(rgb.2))")
            })
        }
        if (t.hasPrefix("{") || t.hasPrefix("[")), let data = t.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            out.append(Action(title: "Copy Pretty JSON", icon: "curlybraces") { copy(String(decoding: pretty, as: UTF8.self)) })
        }
        if t.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/")) != nil, let value = Calculator.evaluate(t) {
            let result = Calculator.format(value)
            out.append(Action(title: "= \(result) (copy)", icon: "equal.circle") { copy(result) })
        }
        if let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), t.count < 200,
           let url = URL(string: "https://duckduckgo.com/?q=\(q)") {
            out.append(Action(title: "Search the Web", icon: "magnifyingglass") { NSWorkspace.shared.open(url) })
        }
        return out
    }

    static func hexColor(_ s: String) -> (Int, Int, Int)? {
        guard s.range(of: #"^#?[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil,
              let v = Int(s.replacingOccurrences(of: "#", with: ""), radix: 16) else { return nil }
        return (v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF)
    }

    @MainActor
    private static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        AppState.shared.hud.show(icon: "doc.on.doc.fill", text: "Copied")
    }
}

/// A tiny arithmetic parser (+ - * / parentheses). NSExpression would crash on bad input.
enum Calculator {
    /// Whole numbers print without a decimal point; huge values use %g (Int(value) would trap past Int.max).
    static func format(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 && abs(value) < 1e15 ? String(Int(value)) : String(format: "%.6g", value)
    }

    static func evaluate(_ s: String) -> Double? {
        var chars = Array(s.filter { !$0.isWhitespace })
        guard !chars.isEmpty, chars.allSatisfy({ "0123456789.+-*/()".contains($0) }) else { return nil }
        var i = 0
        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        func number() -> Double? {
            if peek() == "(" { i += 1; let v = expr(); guard peek() == ")" else { return nil }; i += 1; return v }
            if peek() == "-" { i += 1; return number().map { -$0 } }
            let start = i
            while let c = peek(), c.isNumber || c == "." { i += 1 }
            return i > start ? Double(String(chars[start..<i])) : nil
        }
        func term() -> Double? {
            guard var v = number() else { return nil }
            while let op = peek(), op == "*" || op == "/" {
                i += 1
                guard let r = number() else { return nil }
                v = op == "*" ? v * r : v / r
            }
            return v
        }
        func expr() -> Double? {
            guard var v = term() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = op == "+" ? v + r : v - r
            }
            return v
        }
        let result = expr()
        chars = []
        return i > 0 && result?.isFinite == true ? result : nil
    }
}

// MARK: - Live audio spectrum (system audio via ScreenCaptureKit, FFT with Accelerate)

@MainActor
final class SpectrumModel: ObservableObject {
    @Published private(set) var bands = [Float](repeating: 0, count: 6)
    @Published private(set) var running = false
    private var capture: SpectrumCapture?
    private var retryAfter = Date.distantPast

    func update() {
        let want = Pref.spectrum.bool && AppState.shared.nowPlaying.isPlaying
        if want, capture == nil, Date() > retryAfter {
            let c = SpectrumCapture { [weak self] values in
                Task { @MainActor in self?.receive(values) }
            }
            capture = c
            Task {
                let ok = await c.start()
                // Stopped (or replaced) while starting: don't leave an orphaned capture running.
                guard self.capture === c else { if ok { c.stop() }; return }
                if !ok {
                    self.capture = nil
                    self.retryAfter = Date().addingTimeInterval(60) // e.g. no Screen Recording permission
                }
                self.running = ok
            }
        } else if !want, let c = capture {
            c.stop()
            capture = nil
            running = false
            bands = bands.map { _ in 0 }
        }
    }

    private var lastPublish = Date.distantPast

    private func receive(_ values: [Float]) {
        guard Date().timeIntervalSince(lastPublish) > 1.0 / 30 else { return }
        lastPublish = Date()
        // Fast attack, slow release, like a hardware meter.
        bands = zip(bands, values).map { old, new in new > old ? new : old * 0.82 + new * 0.18 }
    }
}

final class SpectrumCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onBands: @Sendable ([Float]) -> Void
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "islet.spectrum", qos: .userInitiated)
    private var samples: [Float] = []
    private let n = 1024
    private let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
    private let window: [Float]

    init(onBands: @escaping @Sendable ([Float]) -> Void) {
        self.onBands = onBands
        var w = [Float](repeating: 0, count: 1024)
        vDSP_hann_window(&w, vDSP_Length(1024), Int32(vDSP_HANN_NORM))
        window = w
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func start() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return false }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 1
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                                  configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            return true
        } catch {
            return false
        }
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let desc = sampleBuffer.formatDescription, var asbd = desc.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr,
              let data = buffer.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(frames)))
        while samples.count >= n {
            analyze(Array(samples.prefix(n)), sampleRate: Float(format.sampleRate))
            samples.removeFirst(n / 2)
        }
    }

    private func analyze(_ input: [Float], sampleRate: Float) {
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, 10, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        let binHz = sampleRate / Float(n)
        let edges: [Float] = [60, 150, 400, 1000, 2500, 6000, 14000]
        var bands: [Float] = []
        for b in 0..<6 {
            let lo = max(1, Int(edges[b] / binHz)), hi = min(n / 2 - 1, max(lo + 1, Int(edges[b + 1] / binHz)))
            var sum: Float = 0
            for k in lo..<hi { sum += mags[k] }
            let avg = sum / Float(hi - lo)
            let db = 10 * log10(avg + 1e-12)
            bands.append(min(max((db + 10) / 50, 0), 1))
        }
        onBands(bands)
    }
}

// MARK: - Alternate HUD styles (edge bar, circular gauge)

@MainActor
final class HUDOverlay {
    /// What the overlay shows; the hosting view is created once and observes this.
    final class Model: ObservableObject {
        @Published var icon = "speaker.wave.2.fill"
        @Published var progress = 0.0
        @Published var edge = true
        @Published var scale: CGFloat = 1
    }
    private let model = Model()
    private var window: NSWindow?
    private var cancellable: AnyCancellable?

    func start() {
        cancellable = AppState.shared.hud.$current.sink { [weak self] item in
            MainActor.assumeIsolated { self?.update(item) }
        }
    }

    static var usesOverlay: Bool { Pref.hudStyle.string != "island" }

    private func update(_ item: HUDModel.Item?) {
        guard let item, let progress = item.progress, Self.usesOverlay else {
            if let w = window {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; w.animator().alphaValue = 0 }) {
                    Task { @MainActor in if self.window === w, AppState.shared.hud.current?.progress == nil { w.orderOut(nil) } }
                }
            }
            return
        }
        let scale = CGFloat(max(Pref.hudSize.double, 0.5))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let edge = Pref.hudStyle.string == "edge"
        let size = edge ? CGSize(width: 34 * scale, height: 240 * scale) : CGSize(width: 150 * scale, height: 150 * scale)
        let origin = edge
            ? CGPoint(x: screen.visibleFrame.maxX - size.width - 12, y: screen.visibleFrame.midY - size.height / 2)
            : CGPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + 110)
        let w = window ?? {
            let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .statusBar
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            return w
        }()
        window = w
        w.setFrame(NSRect(origin: origin, size: size), display: false)
        if w.contentView == nil {
            let host = NSHostingView(rootView: HUDOverlayView(model: model))
            host.sizingOptions = []
            w.contentView = host
        }
        model.icon = item.icon
        model.edge = edge
        model.scale = scale
        model.progress = progress
        if !w.isVisible || w.alphaValue < 1 {
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; w.animator().alphaValue = 1 }
        }
    }
}

private struct HUDOverlayView: View {
    @ObservedObject var model: HUDOverlay.Model
    private var icon: String { model.icon }
    private var progress: Double { model.progress }
    private var edge: Bool { model.edge }
    private var scale: CGFloat { model.scale }

    var body: some View {
        Group {
            if edge {
                VStack(spacing: 8 * scale) {
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            Capsule().fill(.white.opacity(0.2))
                            Capsule().fill(.white).frame(height: geo.size.height * progress)
                        }
                    }
                    .frame(width: 8 * scale)
                    Image(systemName: icon).font(.system(size: 12 * scale, weight: .semibold))
                }
                .padding(.vertical, 12 * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .adaptiveGlass(GlassSpec.regular.tint(.black.opacity(0.4)), in: .capsule)
            } else {
                ZStack {
                    Circle().stroke(.white.opacity(0.18), lineWidth: 10 * scale)
                    Circle().trim(from: 0, to: progress)
                        .stroke(.white, style: StrokeStyle(lineWidth: 10 * scale, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        Image(systemName: icon).font(.system(size: 26 * scale, weight: .semibold))
                        Text("\(Int(progress * 100))").font(.system(size: 13 * scale, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                }
                .padding(18 * scale)
                .adaptiveGlass(GlassSpec.regular.tint(.black.opacity(0.4)), in: .circle)
            }
        }
        .foregroundStyle(.white)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: progress)
        .padding(2)
    }
}
