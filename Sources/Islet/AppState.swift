import AppKit
import IOKit.pwr_mgt
import Vision

@MainActor
final class AppState {
    static let shared = AppState()

    var nowPlaying: NowPlayingModel { .shared }
    let clipboard = ClipboardModel()
    let shelf = ShelfModel()
    let notes = NotesModel()
    let pomodoro = PomodoroModel()
    let stopwatch = StopwatchModel()
    let keepAwake = KeepAwakeModel()
    let stats = SystemStatsModel()
    let battery = BatteryModel()
    let calendar = CalendarModel()
    let hud = HUDModel()
    let settings = SettingsModel()
    let audio = AudioModel()
    let bluetooth = BluetoothModel()
    let downloads = DownloadsModel()
    let reminders = RemindersModel()
    let snippets = SnippetsModel()
    let terminal = TerminalHost()
    let eq = EQModel()
    let mediaKeys = MediaKeyInterceptor()
    let focus = FocusModel()
    let calls = CallModel()
    let agents = AgentModel()
    let presence = PresenceModel()
    let aiUsage = AIUsageModel()
    let api = LocalAPI()
    let knock = KnockModel()
    let launcher = LauncherModel()
    let drives = DrivesModel()
    let shortcuts = ShortcutsModel()
    let screenshots = ScreenshotWatcher()
    let keyboardTools = KeyboardTools()
    let teleprompter = TeleprompterModel()
    let weather = WeatherModel()
    let stocks = StocksModel()
    let menuBar = MenuBarExtras()
    let feeds = SystemFeeds()
    let shell = ShellModel()
    let spectrum = SpectrumModel()
    let hudOverlay = HUDOverlay()
    let focusSounds = FocusSoundsModel()
    let typingSounds = TypingSoundsModel()
    let cursorEffects = CursorEffects()
    let screenCorners = ScreenCorners()
    let displayTweaks = DisplayTweaks()
    let countdown = CountdownModel()
    let breakReminder = BreakReminder()
    let screenTime = ScreenTimeModel()
    let dataUsage = DataUsageModel()
    let menuBarStatus = MenuBarStatus()
    let meetingAlerts = MeetingAlerts()
    let history = ListeningHistory()
    let desktopLyrics = DesktopLyrics()
    let askAI = AskAIModel()
    let pet = PetModel()
    let screenLight = ScreenLight()

    private var timers: [Timer] = []
    private var defaultsObserver: Any?

    enum Activity: Equatable { case none, hud, call, agent, shell, timer, countdown, music, privacy }

    /// Every activity that currently has something to show, highest priority first.
    var activities: [Activity] {
        var list: [Activity] = []
        if let h = hud.current, !(h.progress != nil && HUDOverlay.usesOverlay) { list.append(.hud) }
        if calls.app != nil { list.append(.call) }
        if agents.active != nil { list.append(.agent) }
        if shell.visible != nil { list.append(.shell) }
        if pomodoro.running { list.append(.timer) }
        if countdown.running { list.append(.countdown) }
        // Now Playing island: while playing, and (unless "Hide When Paused") for a while after pausing.
        if Pref.nowPlayingIsland.bool, nowPlaying.track != nil,
           nowPlaying.isPlaying || !Pref.hideWhenPaused.bool || Date().timeIntervalSince(history.lastPlaying) < 30 {
            list.append(.music)
        }
        if audio.cameraInUse || audio.micInUse { list.append(.privacy) }
        return list
    }

    /// What the collapsed island shows.
    var activity: Activity { activities.first ?? .none }

    /// A second activity shown at the far edge of the pill (Multiple Live Activities).
    var secondaryActivity: Activity? {
        guard Pref.multipleActivities.bool else { return nil }
        let list = activities.filter { $0 != .hud && $0 != .privacy }
        guard let primary = activities.first, let second = list.first(where: { $0 != primary }) else { return nil }
        return second
    }

    /// The idle pill only needs extra width for wide idle content.
    var idleNeedsSpace: Bool { Pref.idleAnimation.string == "weather" && weather.current != nil }

    func start() {
        Prefs.register()
        Pref.register()
        nowPlaying.start()
        schedule(every: 0.25) { $0.audio.fastTick() }
        schedule(every: 0.5) { $0.clipboard.poll(); $0.spectrum.update() }
        schedule(every: 1) {
            $0.pomodoro.tick(); $0.stats.sample(); $0.battery.refresh(); $0.audio.slowTick()
            $0.presence.tick(); $0.agents.tick()
            $0.countdown.tick(); $0.breakReminder.tick(); $0.screenTime.tick(); $0.dataUsage.tick()
            $0.menuBarStatus.tick(); $0.meetingAlerts.tick(); $0.screenLight.tick(); $0.history.tick(); $0.clipboard.autoClear()
        }
        schedule(every: 3) { $0.bluetooth.tick(); $0.focus.refresh(); $0.feeds.poll() }
        schedule(every: 60) { $0.aiUsage.refresh(); $0.reminders.reload(); $0.calendar.reload(); $0.weather.refresh(); $0.stocks.refresh(); $0.pet.checkDailyMemories() }
        stats.sample()
        battery.refresh()
        audio.slowTick()
        audio.fastTick()
        bluetooth.tick()
        aiUsage.refresh()
        calendar.reloadIfAuthorized()
        downloads.setEnabled(settings.downloadAlerts)
        api.setEnabled(settings.localAPI)
        focus.refresh()
        feeds.poll()
        if settings.replaceSystemHUD || Pref.mediaKeys.bool { mediaKeys.setEnabled(true) }
        displayTweaks.applyDim()
        if !Pref.clipKeepAfterQuit.bool { clipboard.clear() }
        shelf.cleanup()
        if settings.presenceLock { presence.setEnabled(true) }
        eq.startup()
        hudOverlay.start()
        weather.refresh()
        applySettings()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppState.shared.applySettings() }
        }
    }

    /// Applies preferences that turn features on or off. Each call is idempotent.
    private var applied: [String: String] = [:]
    func applySettings() {
        func changed(_ keys: Pref...) -> Bool {
            let value = keys.map { "\(UserDefaults.standard.object(forKey: $0.rawValue) ?? "")" }.joined(separator: "|")
            let key = keys.map(\.rawValue).joined(separator: ",")
            defer { applied[key] = value }
            return applied[key] != value
        }
        if changed(.knockEnabled, .knockMethod, .knockKey, .knockSensitivity, .typingProtection, .knockIgnoreClicks) { knock.apply() }
        if changed(.screenshotShelf) { screenshots.setEnabled(Pref.screenshotShelf.bool) }
        if changed(.keystrokeHUD) { keyboardTools.setKeystrokeHUD(Pref.keystrokeHUD.bool) }
        if changed(.menuBarCalendar, .menuBarIconHiding, .menuBarDetach, .hideNotch, .desktopWidgets) { menuBar.apply() }
        if changed(.weatherCity, .weatherFahrenheit) { weather.refreshSoon() }
        if changed(.stocks) { stocks.refreshSoon() }
        if changed(.focusSound, .focusSoundVolume) { focusSounds.apply() }
        if changed(.typingSounds, .typingSoundStyle) { typingSounds.apply() }
        if changed(.cursorEffect) { cursorEffects.apply() }
        if changed(.blackCorners, .cornerRadius) { screenCorners.apply() }
        if changed(.colorTemperature) { displayTweaks.applyTemperature() }
        if changed(.desktopLyrics) { desktopLyrics.apply() }
        if changed(.petEnabled, .petSize) { pet.apply() }
        if changed(.screenLightAllDisplays), screenLight.on { screenLight.apply() }
        if changed(.mediaKeys) { mediaKeys.setEnabled(settings.replaceSystemHUD || Pref.mediaKeys.bool) }
    }

    private func schedule(every interval: TimeInterval, _ body: @escaping @MainActor (AppState) -> Void) {
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { body(AppState.shared) }
        }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }
}

// MARK: - HUD (transient live activity)

@MainActor
final class HUDModel: ObservableObject {
    struct Item: Equatable {
        let icon: String
        let text: String
        var progress: Double?
        /// Bundle id whose app icon replaces the symbol (message/notification islands).
        var app: String?
    }
    @Published private(set) var current: Item?
    private var token = 0

    func show(icon: String, text: String, progress: Double? = nil, seconds: TimeInterval = 2, app: String? = nil) {
        token += 1
        let mine = token
        current = Item(icon: icon, text: text, progress: progress, app: app)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                if self?.token == mine { self?.current = nil }
            }
        }
    }
}

// MARK: - Keep Awake

@MainActor
final class KeepAwakeModel: ObservableObject {
    @Published private(set) var enabled = false
    private var assertion: IOPMAssertionID = 0

    func toggle() {
        if enabled {
            IOPMAssertionRelease(assertion)
            enabled = false
        } else {
            enabled = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Islet Keep Awake" as CFString, &assertion) == kIOReturnSuccess
        }
        AppState.shared.hud.show(icon: enabled ? "cup.and.saucer.fill" : "moon.zzz.fill",
                                 text: enabled ? "Keep Awake on" : "Keep Awake off")
    }
}

// MARK: - Pomodoro

@MainActor
final class PomodoroModel: ObservableObject {
    enum Phase: String { case focus = "Focus", rest = "Break", longRest = "Long Break" }

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var running = false
    /// Counting against an end date keeps the timer exact even if ticks are late (sleep, busy main thread).
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval = 25 * 60
    @Published private(set) var sessionsInCycle = 0
    @Published private(set) var history: [String: Int] = (UserDefaults.standard.dictionary(forKey: "focusHistory") as? [String: Int]) ?? [:]
    @Published var focusMinutes = UserDefaults.standard.object(forKey: "focusMinutes") as? Int ?? 25 {
        didSet { UserDefaults.standard.set(focusMinutes, forKey: "focusMinutes"); if !running && phase == .focus { reset() } }
    }
    @Published var breakMinutes = UserDefaults.standard.object(forKey: "breakMinutes") as? Int ?? 5 {
        didSet { UserDefaults.standard.set(breakMinutes, forKey: "breakMinutes"); if !running && phase == .rest { reset() } }
    }

    init() { pausedRemaining = TimeInterval(focusMinutes * 60) }

    var remaining: Int {
        if let endDate { return max(0, Int(ceil(endDate.timeIntervalSinceNow))) }
        return Int(pausedRemaining)
    }

    var display: String { String(format: "%02d:%02d", remaining / 60, remaining % 60) }

    func progress(at date: Date = Date()) -> Double {
        let total = duration(of: phase)
        let left = endDate.map { max(0, $0.timeIntervalSince(date)) } ?? pausedRemaining
        return total > 0 ? 1 - left / total : 0
    }

    func duration(of phase: Phase) -> TimeInterval {
        switch phase {
        case .focus: return TimeInterval(focusMinutes * 60)
        case .rest: return TimeInterval(breakMinutes * 60)
        case .longRest: return TimeInterval(max(Pref.pomoLongBreak.int, 1) * 60)
        }
    }

    func toggle() {
        if let endDate {
            pausedRemaining = max(0, endDate.timeIntervalSinceNow)
            self.endDate = nil
            running = false
        } else {
            endDate = Date().addingTimeInterval(pausedRemaining)
            running = true
        }
    }

    func reset() {
        running = false
        endDate = nil
        pausedRemaining = duration(of: phase)
    }

    func skip() { advance(completed: false) }

    func tick() {
        guard let endDate, Date() >= endDate else { return }
        advance(completed: true)
    }

    private func advance(completed: Bool) {
        let finished = phase
        if finished == .focus, completed, Pref.focusSoundStopWithPomodoro.bool, Pref.focusSound.string != "none" {
            Pref.focusSound.set("none")
        }
        if finished == .focus {
            if completed {
                history[Self.dayKey(Date()), default: 0] += focusMinutes
                UserDefaults.standard.set(history, forKey: "focusHistory")
            }
            sessionsInCycle += 1
            phase = sessionsInCycle % max(Pref.pomoLongEvery.int, 1) == 0 ? .longRest : .rest
        } else {
            phase = .focus
        }
        pausedRemaining = duration(of: phase)
        let autoStart = phase == .focus ? Pref.pomoAutoFocus.bool : Pref.pomoAutoBreak.bool
        endDate = completed && autoStart ? Date().addingTimeInterval(pausedRemaining) : nil
        running = endDate != nil

        guard completed else { return }
        NSSound(named: NSSound.Name(Pref.pomoSound.string))?.play()
        let text: String
        switch finished {
        case .focus: text = phase == .longRest ? "Great work — take a long break" : "Focus done, take a break"
        default: text = "Break over — back to it"
        }
        AppState.shared.hud.show(icon: finished == .focus ? "checkmark.circle.fill" : "bell.fill", text: text, seconds: 4)
    }

    // MARK: Stats

    var todayMinutes: Int { history[Self.dayKey(Date())] ?? 0 }
    var todaySessions: Int { todayMinutes / max(focusMinutes, 1) }

    /// Consecutive days with focus time, counting back from today (or yesterday if today is empty so far).
    var streak: Int {
        var day = Date()
        if history[Self.dayKey(day)] == nil { day = Calendar.current.date(byAdding: .day, value: -1, to: day)! }
        var count = 0
        while (history[Self.dayKey(day)] ?? 0) > 0 {
            count += 1
            day = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    var lastSevenDays: [(day: Date, minutes: Int)] {
        (0..<7).reversed().map { offset in
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: Calendar.current.startOfDay(for: Date()))!
            return (day, history[Self.dayKey(day)] ?? 0)
        }
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

/// A stopwatch measured from start dates, so it never drifts.
@MainActor
final class StopwatchModel: ObservableObject {
    @Published private(set) var startDate: Date?
    @Published private(set) var accumulated: TimeInterval = 0
    @Published private(set) var laps: [TimeInterval] = []

    var running: Bool { startDate != nil }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        accumulated + (startDate.map { date.timeIntervalSince($0) } ?? 0)
    }

    func toggle() {
        if let startDate {
            accumulated += Date().timeIntervalSince(startDate)
            self.startDate = nil
        } else {
            startDate = Date()
        }
    }

    func lap() { if running { laps.insert(elapsed(), at: 0) } }

    func reset() {
        startDate = nil
        accumulated = 0
        laps = []
    }

    static func format(_ t: TimeInterval) -> String {
        let cs = Int((t * 100).rounded(.down))
        let h = cs / 360_000, m = cs / 6000 % 60, s = cs / 100 % 60, f = cs % 100
        return h > 0 ? String(format: "%d:%02d:%02d.%02d", h, m, s, f) : String(format: "%02d:%02d.%02d", m, s, f)
    }
}

// MARK: - Notes

@MainActor
final class NotesModel: ObservableObject {
    @Published var text = UserDefaults.standard.string(forKey: "notes") ?? "" {
        didSet { UserDefaults.standard.set(text, forKey: "notes") }
    }
}

// MARK: - Clipboard history

@MainActor
final class ClipboardModel: ObservableObject {
    struct Item: Identifiable, Codable, Equatable {
        var id = UUID()
        /// The copied text, or for images the text found by OCR.
        var text: String
        let date: Date
        var imageFile: String?
    }

    @Published private(set) var items: [Item] = []
    private var changeCount = NSPasteboard.general.changeCount
    private var limit: Int { max(Pref.clipLimit.int, 10) }
    private var lastClear = Date()
    private let imageDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Islet/Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        if let data = UserDefaults.standard.data(forKey: "clipboard"),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
        // Purge secrets saved before "skip secrets" existed.
        if Pref.clipSkipSecrets.bool, items.contains(where: { Self.looksSecret($0.text) }) {
            items.removeAll { Self.looksSecret($0.text) }
            UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: "clipboard")
        }
    }

    /// API keys, tokens and private keys shouldn't sit in clipboard history.
    static func looksSecret(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"\bsk-(ant-)?[A-Za-z0-9_\-]{20,}"#,                 // Anthropic / OpenAI
            #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}"#, #"\bgithub_pat_[A-Za-z0-9_]{30,}"#,
            #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#,                    // Slack
            #"\bAKIA[0-9A-Z]{16}\b"#,                             // AWS access key
            #"\bAIza[0-9A-Za-z_\-]{35}\b"#,                      // Google API key
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            #"^eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}$"#, // JWT
        ]
        return patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    func imageURL(_ item: Item) -> URL? { item.imageFile.map { imageDir.appendingPathComponent($0) } }

    /// Small, cached thumbnails so the list doesn't decode full images from disk on every redraw.
    private let thumbnails = NSCache<NSString, NSImage>()

    func thumbnail(_ item: Item) -> NSImage? {
        guard let file = item.imageFile else { return nil }
        if let cached = thumbnails.object(forKey: file as NSString) { return cached }
        guard let url = imageURL(item), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 96] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        thumbnails.setObject(image, forKey: file as NSString)
        return image
    }

    func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        // Respect password managers that mark their copies as concealed/transient.
        let skip = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"].map { NSPasteboard.PasteboardType($0) }
        if pb.types?.contains(where: skip.contains) == true { return }
        if Pref.clipPaused.bool { return }
        // Skip copies made in ignored apps (password managers by default).
        let ignored = Set(Pref.clipIgnore.string.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, ignored.contains(front) { return }

        if var s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if Pref.clipStripTracking.bool, let clean = Self.stripTracking(s), clean != s {
                s = clean
                pb.clearContents()
                pb.setString(clean, forType: .string)
                changeCount = pb.changeCount
            }
            if Pref.clipSkipSecrets.bool, Self.looksSecret(s) { return }
            if Pref.clipSound.bool { NSSound(named: "Tink")?.play() }
            items.removeAll { $0.imageFile == nil && $0.text == s }
            insert(Item(text: s, date: Date()))
        } else if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let item = Item(text: "", date: Date(), imageFile: UUID().uuidString + ".png")
            guard (try? png.write(to: imageDir.appendingPathComponent(item.imageFile!))) != nil else { return }
            insert(item)
            recognizeText(in: png, for: item.id)
        }
    }

    /// Removes tracking parameters (utm_*, fbclid, gclid, …) from a copied link.
    static func stripTracking(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), var c = URLComponents(string: t), c.scheme?.hasPrefix("http") == true, let items = c.queryItems else { return nil }
        let junk: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "igshid", "mc_eid", "mc_cid", "si", "yclid", "_hsenc", "_hsmi", "ref_src", "spm"]
        let kept = items.filter { !$0.name.hasPrefix("utm_") && !junk.contains($0.name) }
        guard kept.count != items.count else { return nil }
        c.queryItems = kept.isEmpty ? nil : kept
        return c.string
    }

    /// Settings → Clipboard → Auto-clear: after an hour, a day, or on sleep / lock.
    func autoClear() {
        let mode = Pref.clipAutoClear.string
        let age: TimeInterval? = mode == "1h" ? 3600 : mode == "1d" ? 86400 : nil
        if let age, Date().timeIntervalSince(lastClear) > 60 {
            lastClear = Date()
            let old = items.filter { Date().timeIntervalSince($0.date) > age }
            if !old.isEmpty { old.forEach(remove) }
        }
        if !sleepObservers {
            sleepObservers = true
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if Pref.clipAutoClear.string == "sleep" { AppState.shared.clipboard.clear() } }
            }
            DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if ["lock", "sleep"].contains(Pref.clipAutoClear.string) { AppState.shared.clipboard.clear() } }
            }
        }
    }
    private var sleepObservers = false

    private func insert(_ item: Item) {
        items.insert(item, at: 0)
        while items.count > limit { deleteFile(items.removeLast()) }
        save()
    }

    /// OCR so screenshots and copied images are searchable.
    private func recognizeText(in png: Data, for id: UUID) {
        DispatchQueue.global(qos: .utility).async {
            guard let cg = NSBitmapImageRep(data: png)?.cgImage else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: cg).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            Task { @MainActor in
                guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[i].text = text
                self.save()
            }
        }
    }

    func copy(_ item: Item) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let url = imageURL(item), let image = NSImage(contentsOf: url) {
            pb.writeObjects([image])
        } else {
            pb.setString(item.text, forType: .string)
        }
        AppState.shared.hud.show(icon: "doc.on.doc.fill", text: "Copied")
    }

    func remove(_ item: Item) {
        deleteFile(item)
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.forEach(deleteFile)
        items.removeAll()
        save()
    }

    private func deleteFile(_ item: Item) {
        if let url = imageURL(item) { try? FileManager.default.removeItem(at: url) }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: "clipboard")
    }
}

// MARK: - File shelf

@MainActor
final class ShelfModel: ObservableObject {
    @Published private(set) var files: [URL] = []

    init() {
        files = (UserDefaults.standard.stringArray(forKey: "shelf") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var added: [String: Date] = (UserDefaults.standard.dictionary(forKey: "shelfDates") as? [String: Date]) ?? [:]
    private let copies = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Islet/Shelf", isDirectory: true)

    func add(_ url: URL) {
        var url = url
        // "Independent copies": keep the shelf item even if the original moves or is deleted.
        if Pref.shelfCopyFiles.bool, !url.path.hasPrefix(copies.path) {
            try? FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
            let dest = FileTools.unique(copies.appendingPathComponent(url.lastPathComponent))
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { url = dest }
        }
        guard !files.contains(url) else { return }
        files.append(url)
        added[url.path] = Date()
        save()
    }

    /// Settings → Shelf → remove items after N days.
    func cleanup() {
        let days = Pref.shelfCleanupDays.int
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        files.filter { (added[$0.path] ?? .distantPast) < cutoff }.forEach(remove)
    }

    func remove(_ url: URL) { files.removeAll { $0 == url }; save() }
    func clear() { files.removeAll(); save() }

    func airDrop(_ urls: [URL]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    private func save() {
        UserDefaults.standard.set(files.map(\.path), forKey: "shelf")
        UserDefaults.standard.set(added, forKey: "shelfDates")
    }
}
