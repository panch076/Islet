import AppKit
import SwiftUI

// MARK: - Desk pet: a little creature that lives on your desktop.
// Walks along the bottom of the screen (or rides on top of the front window), naps at bedtime,
// dresses for the weather and holidays, and has needs you can look after from the island.

enum PetCatalog {
    /// 52 characters.
    static let species: [(emoji: String, name: String)] = [
        ("🐱", "Cat"), ("🐶", "Dog"), ("🦊", "Fox"), ("🐰", "Bunny"), ("🐻", "Bear"), ("🐼", "Panda"), ("🐨", "Koala"),
        ("🐯", "Tiger"), ("🦁", "Lion"), ("🐮", "Cow"), ("🐷", "Pig"), ("🐸", "Frog"), ("🐵", "Monkey"), ("🐔", "Chicken"),
        ("🐧", "Penguin"), ("🐦", "Bird"), ("🐤", "Chick"), ("🦆", "Duck"), ("🦉", "Owl"), ("🦄", "Unicorn"), ("🐴", "Horse"),
        ("🐝", "Bee"), ("🐛", "Caterpillar"), ("🦋", "Butterfly"), ("🐌", "Snail"), ("🐞", "Ladybug"), ("🐢", "Turtle"),
        ("🐍", "Snake"), ("🦎", "Lizard"), ("🦖", "T-Rex"), ("🦕", "Dino"), ("🐙", "Octopus"), ("🦀", "Crab"), ("🐠", "Fish"),
        ("🐬", "Dolphin"), ("🐳", "Whale"), ("🦭", "Seal"), ("🐊", "Croc"), ("🐆", "Leopard"), ("🦓", "Zebra"), ("🦒", "Giraffe"),
        ("🦘", "Kangaroo"), ("🐿️", "Squirrel"), ("🦔", "Hedgehog"), ("🦇", "Bat"), ("🐺", "Wolf"), ("🦝", "Raccoon"),
        ("🦥", "Sloth"), ("🦦", "Otter"), ("🐉", "Dragon"), ("👻", "Ghost"), ("🤖", "Robot"),
    ]

    static let fish: [(emoji: String, name: String, rarity: Int)] = [
        ("🐟", "Minnow", 50), ("🐠", "Tropical fish", 25), ("🐡", "Pufferfish", 12), ("🦐", "Shrimp", 20),
        ("🦑", "Squid", 8), ("🐙", "Octopus", 5), ("🦞", "Lobster", 4), ("🐢", "Sea turtle", 2), ("🦈", "Shark", 1),
        ("👢", "Old boot", 15), ("💎", "Diamond", 1),
    ]

    static func name(for emoji: String) -> String { species.first { $0.emoji == emoji }?.name ?? "Pet" }
}

enum PetPersonality: String, CaseIterable, Identifiable {
    case playful, lazy, curious, grumpy, shy
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// How often it wanders, how fast it walks (pt/s), and what it says.
    var wanderChance: Double { [.playful: 0.7, .lazy: 0.2, .curious: 0.6, .grumpy: 0.35, .shy: 0.4][self]! }
    var speed: CGFloat { [.playful: 90, .lazy: 35, .curious: 60, .grumpy: 45, .shy: 50][self]! }
    var idleLines: [String] {
        switch self {
        case .playful: return ["Play with me!", "Wheee!", "Catch me!", "Let's do something fun"]
        case .lazy: return ["*yawn*", "Five more minutes…", "Comfy.", "Is it nap time?"]
        case .curious: return ["What's that window?", "Ooh, what are you working on?", "Hmm…", "So many icons!"]
        case .grumpy: return ["Hmph.", "Don't touch me.", "Fine.", "What now?"]
        case .shy: return ["…hi", "*peeks*", "Oh! You're here.", "…"]
        }
    }
}

struct PetData: Codable {
    var fullness = 0.8
    var happiness = 0.8
    var energy = 0.9
    var born = Date()
    var fed = 0
    var petted = 0
    var played = 0
    var memories: [Memory] = []
    var catches: [String: Int] = [:]
    var lastTick = Date()

    struct Memory: Codable, Identifiable {
        var id = UUID()
        let date: Date
        let icon: String
        let text: String
    }
}

@MainActor
final class PetModel: ObservableObject {
    enum Behavior: Equatable { case idle, walking, sitting, sleeping, eating, happy, dragged, falling, fishing }
    enum FishingState: Equatable { case idle, waiting, bite, caught(String), missed }

    @Published private(set) var data: PetData
    @Published private(set) var behavior: Behavior = .idle
    @Published private(set) var facingRight = false
    @Published private(set) var bubble: String?
    @Published private(set) var hearts: [UUID] = []
    @Published private(set) var fishing: FishingState = .idle
    @Published private(set) var groundIsWindow = false

    // Position: horizontal centre and feet height, in screen coordinates.
    private(set) var x: CGFloat = 0
    private(set) var y: CGFloat = 0
    private var vy: CGFloat = 0
    private var targetX: CGFloat?
    private var behaviorUntil = Date()
    private var nextBubble = Date().addingTimeInterval(20)
    private var ground: (y: CGFloat, minX: CGFloat, maxX: CGFloat)?
    private var lastGroundCheck = Date.distantPast
    private var lastFrame = Date()
    private var window: PetWindow?
    private var timer: Timer?
    private var saveCounter = 0
    private var dragOffset: CGSize = .zero

    var species: String { Pref.petSpecies.string.isEmpty ? "🐱" : Pref.petSpecies.string }
    var name: String { Pref.petName.string.isEmpty ? PetCatalog.name(for: species) : Pref.petName.string }
    var personality: PetPersonality { PetPersonality(rawValue: Pref.petPersonality.string) ?? .playful }
    var size: CGFloat { CGFloat(max(Pref.petSize.double, 24)) }
    var age: Int { Calendar.current.dateComponents([.day], from: data.born, to: Date()).day ?? 0 }

    init() {
        if let raw = UserDefaults.standard.data(forKey: "petData"), let saved = try? JSONDecoder().decode(PetData.self, from: raw) {
            data = saved
        } else {
            data = PetData()
            data.memories.append(.init(date: Date(), icon: "sparkles", text: "We met for the first time!"))
        }
        catchUp()
    }

    // MARK: Lifecycle

    func apply() {
        guard Pref.petEnabled.bool else {
            timer?.invalidate()
            timer = nil
            window?.orderOut(nil)
            window = nil
            return
        }
        if window == nil {
            let w = PetWindow(model: self)
            window = w
            let screen = NSScreen.main ?? NSScreen.screens[0]
            x = screen.visibleFrame.midX + .random(in: -200...200)
            y = screen.visibleFrame.minY
            w.orderFrontRegardless()
        }
        window?.resize(for: size)
        if timer == nil {
            lastFrame = Date()
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.frame() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        placeWindow()
    }

    /// Needs drift while Islet wasn't running (gently, capped).
    private func catchUp() {
        let hours = min(Date().timeIntervalSince(data.lastTick) / 3600, 24)
        data.fullness = max(0.15, data.fullness - hours * 0.04)
        data.happiness = max(0.2, data.happiness - hours * 0.03)
        data.energy = min(1, data.energy + hours * 0.05)
        data.lastTick = Date()
    }

    // MARK: Per-frame update

    private func frame() {
        let now = Date()
        let dt = CGFloat(min(now.timeIntervalSince(lastFrame), 0.1))
        lastFrame = now
        let moving = behavior == .walking || behavior == .falling || behavior == .dragged

        // Idle frames are cheap: only do full work ~5×/s unless something moves.
        saveCounter += 1
        if !moving && saveCounter % 6 != 0 { return }

        updateGround()
        updateNeeds(dt: moving ? dt : dt * 6)
        decide(now)

        switch behavior {
        case .walking:
            guard let target = targetX else { behavior = .idle; break }
            let step = personality.speed * dt * (data.energy < 0.25 ? 0.5 : 1)
            if abs(target - x) <= step {
                x = target
                targetX = nil
                behavior = Bool.random() ? .sitting : .idle
                behaviorUntil = now.addingTimeInterval(.random(in: 3...9))
            } else {
                x += target > x ? step : -step
            }
            y = ground?.y ?? y
            // Walked off the end of the window it was riding: drop down.
            if let g = ground, groundIsWindow, x < g.minX || x > g.maxX { startFalling() }
        case .falling:
            vy -= 1800 * dt
            y += vy * dt
            let floor = groundHeight(at: x)
            if y <= floor {
                y = floor
                vy = 0
                behavior = .idle
                behaviorUntil = now.addingTimeInterval(1.5)
                say(["Oof!", "Safe landing.", "Whoa!"].randomElement()!)
            }
        case .dragged:
            let m = NSEvent.mouseLocation
            x = m.x - dragOffset.width
            y = m.y - dragOffset.height
        default:
            // Keep standing on a window that moved.
            if behavior != .fishing, let g = ground, abs(g.y - y) > 1 {
                if g.y < y { startFalling() } else { y = g.y }
            }
        }
        placeWindow()
        if saveCounter % 900 == 0 { save() } // ~every 30 s
    }

    private func placeWindow() {
        window?.place(feetAt: CGPoint(x: x, y: y), size: size)
    }

    // MARK: Needs

    private func updateNeeds(dt: CGFloat) {
        let perSecond = Double(dt) / 3600 // rates below are "per hour"
        let sleeping = behavior == .sleeping
        data.fullness = max(0, data.fullness - perSecond * 0.06)
        data.happiness = max(0, data.happiness - perSecond * (data.fullness < 0.3 ? 0.08 : 0.03))
        data.energy = sleeping ? min(1, data.energy + perSecond * 0.25) : max(0, data.energy - perSecond * 0.05)
        data.lastTick = Date()
    }

    // MARK: Behaviour

    private var isBedtime: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        let start = Pref.petBedStart.int, end = Pref.petBedEnd.int
        return start > end ? (hour >= start || hour < end) : (hour >= start && hour < end)
    }

    private func decide(_ now: Date) {
        if [.dragged, .falling, .fishing].contains(behavior) { return }
        if behavior == .sleeping {
            if (!isBedtime && data.energy > 0.6) || now > behaviorUntil && !isBedtime && data.energy > 0.95 { wake() }
            return
        }
        if isBedtime || data.energy < 0.12 {
            behavior = .sleeping
            behaviorUntil = now.addingTimeInterval(600)
            bubble = nil
            return
        }
        if now >= behaviorUntil, behavior != .walking {
            if Double.random(in: 0...1) < personality.wanderChance * (data.energy < 0.3 ? 0.4 : 1) {
                let range = ground.map { ($0.minX + size / 2)...($0.maxX - size / 2) }
                    ?? ((NSScreen.main?.visibleFrame.minX ?? 0) + 40)...((NSScreen.main?.visibleFrame.maxX ?? 800) - 40)
                if range.lowerBound < range.upperBound {
                    targetX = .random(in: range)
                    facingRight = (targetX ?? x) > x
                    behavior = .walking
                }
            } else {
                behavior = Bool.random() ? .sitting : .idle
                behaviorUntil = now.addingTimeInterval(.random(in: 4...12))
            }
        }
        if Pref.petSpeech.bool, now >= nextBubble {
            nextBubble = now.addingTimeInterval(.random(in: 45...120))
            say(contextLine())
        }
    }

    private func contextLine() -> String {
        if data.fullness < 0.25 { return ["I'm hungry…", "Snack, please?", "My tummy is rumbling"].randomElement()! }
        if data.happiness < 0.3 { return ["I'm lonely", "Pet me?", "Play with me?"].randomElement()! }
        if data.energy < 0.25 { return "So sleepy…" }
        let s = AppState.shared
        if s.pomodoro.running, s.pomodoro.phase == .focus { return ["Focus! You've got this.", "Shh, focus time", "Keep going!"].randomElement()! }
        if s.nowPlaying.isPlaying, let t = s.nowPlaying.track { return Bool.random() ? "🎵 \(t.title)" : "I like this song!" }
        if s.battery.hasBattery, s.battery.percent < 15, !s.battery.pluggedIn { return "Battery's low!" }
        if let w = s.weather.current, Bool.random() {
            switch WeatherModel.symbol(w.code) {
            case "cloud.rain.fill", "cloud.drizzle.fill", "cloud.bolt.rain.fill": return "Good thing I have an umbrella"
            case "cloud.snow.fill": return "Snow day!"
            case "sun.max.fill": return "Sunny out there!"
            default: break
            }
        }
        return personality.idleLines.randomElement()!
    }

    func say(_ text: String, for seconds: TimeInterval = 4) {
        bubble = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { if self?.bubble == text { self?.bubble = nil } }
        }
    }

    // MARK: Ground (desktop floor or the top of the front window)

    private func updateGround() {
        guard Date().timeIntervalSince(lastGroundCheck) > 0.4 else { return }
        lastGroundCheck = Date()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let floor = (y: screen.visibleFrame.minY, minX: screen.visibleFrame.minX, maxX: screen.visibleFrame.maxX)
        guard Pref.petWindowRides.bool, behavior != .sleeping, let top = frontWindowTop(on: screen),
              x >= top.minX, x <= top.maxX else {
            ground = floor
            if groundIsWindow { groundIsWindow = false; if behavior != .dragged { startFalling() } }
            return
        }
        // Only hop onto a window that's actually under the pet.
        if groundIsWindow || abs(top.y - y) < 4 || behavior == .falling {
            ground = top
            if !groundIsWindow { groundIsWindow = true }
        } else {
            ground = floor
        }
    }

    private func groundHeight(at x: CGFloat) -> CGFloat {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        if Pref.petWindowRides.bool, let top = frontWindowTop(on: screen), x >= top.minX, x <= top.maxX, top.y <= y + 2 {
            groundIsWindow = true
            ground = top
            return top.y
        }
        groundIsWindow = false
        return screen.visibleFrame.minY
    }

    /// Top edge of the front app's main window, in screen coordinates.
    private func frontWindowTop(on screen: NSScreen) -> (y: CGFloat, minX: CGFloat, maxX: CGFloat)? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first?.frame.height else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat], let width = b["Width"], width > 200,
                  let height = b["Height"], height > 150 else { continue }
            let top = primary - (b["Y"] ?? 0)
            let minX = b["X"] ?? 0
            // Ignore full-screen-ish windows and ones whose top is under the menu bar.
            guard top < screen.visibleFrame.maxY - size, top > screen.visibleFrame.minY + 40 else { return nil }
            return (top, minX + 10, minX + width - 10)
        }
        return nil
    }

    private func startFalling() {
        behavior = .falling
        vy = 0
        targetX = nil
    }

    // MARK: Interactions

    func petted() {
        if behavior == .sleeping { wake(); say("Huh? Oh, hi!"); return }
        data.petted += 1
        data.happiness = min(1, data.happiness + 0.08)
        showHearts()
        behavior = .happy
        behaviorUntil = Date().addingTimeInterval(1.5)
        if personality == .grumpy, Bool.random() { say("…fine. That's nice.") } else if Bool.random() { say(["Purr~", "Hehe", "♥", "More!"].randomElement()!) }
        milestone(data.petted, every: 25, icon: "hand.raised.fill", "Petted \(data.petted) times")
    }

    func feed() {
        if behavior == .sleeping { wake() }
        guard data.fullness < 0.97 else { say("I'm full!"); return }
        data.fed += 1
        data.fullness = min(1, data.fullness + 0.3)
        data.happiness = min(1, data.happiness + 0.04)
        behavior = .eating
        behaviorUntil = Date().addingTimeInterval(2.5)
        say(["Yum!", "Nom nom", "Delicious!", "Thank you!"].randomElement()!)
        milestone(data.fed, every: 10, icon: "fork.knife", "Shared \(data.fed) meals")
    }

    func play() {
        if behavior == .sleeping { wake() }
        guard data.energy > 0.15 else { say("Too tired to play…"); return }
        data.played += 1
        data.happiness = min(1, data.happiness + 0.15)
        data.energy = max(0, data.energy - 0.08)
        data.fullness = max(0, data.fullness - 0.03)
        showHearts()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        targetX = min(max(x + (Bool.random() ? 1 : -1) * .random(in: 150...350), screen.visibleFrame.minX + 40), screen.visibleFrame.maxX - 40)
        facingRight = (targetX ?? x) > x
        behavior = .walking
        say(["Wheee!", "Again!", "So fun!"].randomElement()!)
        milestone(data.played, every: 10, icon: "figure.play", "Played together \(data.played) times")
    }

    func toggleSleep() {
        if behavior == .sleeping { wake() } else {
            behavior = .sleeping
            behaviorUntil = Date().addingTimeInterval(1800)
            bubble = nil
        }
    }

    private func wake() {
        behavior = .idle
        behaviorUntil = Date().addingTimeInterval(3)
    }

    func beginDrag(at mouse: CGPoint) {
        dragOffset = CGSize(width: mouse.x - x, height: mouse.y - y)
        behavior = .dragged
        say(personality == .grumpy ? "Put me down!" : "Wheee~", for: 2)
    }

    func endDrag() {
        guard behavior == .dragged else { return }
        lastGroundCheck = .distantPast
        startFalling()
    }

    private func showHearts() {
        let id = UUID()
        hearts.append(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated { self?.hearts.removeAll { $0 == id } }
        }
    }

    // MARK: Fishing (played from the island's Pet tab)

    func cast() {
        guard fishing == .idle || fishing == .missed || { if case .caught = fishing { return true }; return false }() else { return }
        fishing = .waiting
        behavior = .fishing
        let wait = Double.random(in: 2...6)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fishing == .waiting else { return }
                self.fishing = .bite
                NSSound(named: "Pop")?.play()
                // A short window to reel in.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.fishing == .bite else { return }
                        self.fishing = .missed
                        self.behavior = .idle
                    }
                }
            }
        }
    }

    func reel() {
        switch fishing {
        case .bite:
            let total = PetCatalog.fish.reduce(0) { $0 + $1.rarity }
            var roll = Int.random(in: 0..<total)
            var fish = PetCatalog.fish[0]
            for f in PetCatalog.fish {
                if roll < f.rarity { fish = f; break }
                roll -= f.rarity
            }
            data.catches[fish.emoji, default: 0] += 1
            fishing = .caught(fish.emoji)
            behavior = .happy
            behaviorUntil = Date().addingTimeInterval(2)
            data.happiness = min(1, data.happiness + 0.05)
            say("Caught a \(fish.name.lowercased())! \(fish.emoji)")
            if data.catches[fish.emoji] == 1 {
                remember(fish.rarity <= 2 ? "star.fill" : "fish.fill", "First \(fish.name.lowercased()) \(fish.emoji)")
            }
        case .waiting:
            fishing = .missed
            behavior = .idle
            say("Too early!")
        default:
            cast()
        }
    }

    // MARK: Memories

    private func milestone(_ count: Int, every n: Int, icon: String, _ text: String) {
        if count % n == 0 { remember(icon, text) }
    }

    func remember(_ icon: String, _ text: String) {
        data.memories.insert(.init(date: Date(), icon: icon, text: text), at: 0)
        if data.memories.count > 200 { data.memories.removeLast() }
        save()
    }

    func checkDailyMemories() {
        let days = age
        if days > 0, [7, 30, 100, 365].contains(days), !data.memories.contains(where: { $0.text.contains("\(days) days") }) {
            remember("birthday.cake.fill", "\(days) days together!")
        }
        if let holiday = PetOutfits.holiday(), !data.memories.contains(where: { Calendar.current.isDateInToday($0.date) && $0.text.contains(holiday.name) }) {
            remember("gift.fill", "Celebrated \(holiday.name) together \(holiday.emoji)")
        }
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(data), forKey: "petData")
    }

    func reset() {
        data = PetData()
        data.memories.append(.init(date: Date(), icon: "sparkles", text: "We met for the first time!"))
        save()
    }

    func exportData() -> Data? { try? JSONEncoder().encode(data) }

    func importData(_ raw: Data) -> Bool {
        guard let d = try? JSONDecoder().decode(PetData.self, from: raw) else { return false }
        data = d
        save()
        return true
    }

    var isSleeping: Bool { behavior == .sleeping }
}

// MARK: - Outfits for weather and holidays

enum PetOutfits {
    static func holiday(_ date: Date = Date()) -> (name: String, emoji: String)? {
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        switch (c.month ?? 0, c.day ?? 0) {
        case (10, 24...31): return ("Halloween", "🎃")
        case (12, 18...26): return ("Christmas", "🎄")
        case (12, 31), (1, 1): return ("New Year", "🎉")
        case (2, 14): return ("Valentine's Day", "💝")
        case (3, 17): return ("St. Patrick's Day", "☘️")
        case (7, 4): return ("Independence Day", "🎆")
        default: return nil
        }
    }

    /// Hat or prop above the pet's head.
    @MainActor
    static func headwear(sleeping: Bool) -> String? {
        if sleeping { return nil }
        if Pref.petHolidayOutfits.bool, let h = holiday() {
            switch h.name {
            case "Halloween": return "🎃"
            case "Christmas": return "🎅"
            case "New Year": return "🥳"
            case "Valentine's Day": return "💝"
            case "St. Patrick's Day": return "☘️"
            default: return h.emoji
            }
        }
        guard Pref.petWeatherOutfits.bool, let w = AppState.shared.weather.current else { return nil }
        switch WeatherModel.symbol(w.code) {
        case "cloud.rain.fill", "cloud.drizzle.fill", "cloud.bolt.rain.fill": return "☂️"
        case "cloud.snow.fill": return "🧣"
        case "sun.max.fill": return w.temp > (Pref.weatherFahrenheit.bool ? 80 : 27) ? "🕶️" : nil
        default: return nil
        }
    }
}

// MARK: - The pet's own window (follows the pet around the desktop)

final class PetWindow: NSPanel {
    private weak var model: PetModel?
    private let bubbleRoom: CGFloat = 70

    @MainActor
    init(model: PetModel) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: 160), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        let host = NSHostingView(rootView: PetView(model: model))
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { false }

    @MainActor
    func resize(for size: CGFloat) {
        setContentSize(NSSize(width: max(220, size * 3), height: size * 1.6 + bubbleRoom))
    }

    @MainActor
    func place(feetAt p: CGPoint, size: CGFloat) {
        let origin = NSPoint(x: (p.x - frame.width / 2).rounded(), y: p.y.rounded())
        if frame.origin != origin { setFrameOrigin(origin) }
        // Click-through except over the pet itself.
        let mouse = NSEvent.mouseLocation
        let petRect = NSRect(x: p.x - size / 2, y: p.y, width: size, height: size * 1.1)
        let over = petRect.insetBy(dx: -6, dy: -6).contains(mouse) || NSEvent.pressedMouseButtons != 0 && model?.behavior == .dragged
        if ignoresMouseEvents == over { ignoresMouseEvents = !over }
    }
}

private struct PetView: View {
    @ObservedObject var model: PetModel
    @AppStorage(Pref.petSpecies.rawValue) private var species = "🐱"
    @AppStorage(Pref.petHue.rawValue) private var hue = 0.0
    @AppStorage(Pref.petSize.rawValue) private var size = 56.0

    var body: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            if let text = model.bubble {
                Text(text)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .adaptiveGlass(GlassSpec.regular.tint(.black.opacity(0.35)), in: .capsule)
                    .frame(maxWidth: 200)
                    .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
            }
            critter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(Motion.standard, value: model.bubble)
        .contextMenu {
            Button("Feed \(model.name)") { model.feed() }
            Button("Pet") { model.petted() }
            Button("Play") { model.play() }
            Button(model.isSleeping ? "Wake Up" : "Nap") { model.toggleSleep() }
            Divider()
            Button("Open Pet Room") { NotchController.current?.open(tab: .pet) }
            Button("Pet Settings…") { SettingsWindowController.shared.show(.pet) }
            Button("Hide Pet") { Pref.petEnabled.set(false) }
        }
    }

    private var critter: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .bottom) {
                Ellipse().fill(.black.opacity(model.behavior == .falling || model.behavior == .dragged ? 0.08 : 0.25))
                    .frame(width: size * 0.7, height: size * 0.12)
                    .blur(radius: 2)
                Text(species)
                    .font(.system(size: size * 0.85))
                    .hueRotation(.degrees(hue))
                    .scaleEffect(x: model.facingRight ? -1 : 1, y: 1)
                    .scaleEffect(x: squash(t).x, y: squash(t).y, anchor: .bottom)
                    .rotationEffect(.degrees(model.behavior == .dragged ? sin(t * 6) * 12 : 0), anchor: .top)
                    .offset(y: -bob(t))
                    .overlay(alignment: .top) {
                        if let hat = PetOutfits.headwear(sleeping: model.isSleeping) {
                            Text(hat).font(.system(size: size * 0.35)).offset(y: -size * 0.22 - bob(t))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if model.isSleeping {
                            Text("💤").font(.system(size: size * 0.3))
                                .offset(x: size * 0.2, y: -size * 0.15 - CGFloat(sin(t * 1.5) * 4))
                        } else if model.behavior == .eating {
                            Text("🍖").font(.system(size: size * 0.32)).offset(x: size * 0.15)
                        } else if model.behavior == .fishing {
                            Text("🎣").font(.system(size: size * 0.4)).offset(x: size * 0.35, y: -size * 0.1)
                        }
                    }
                    .opacity(model.isSleeping ? 0.85 : 1)
                ForEach(Array(model.hearts.enumerated()), id: \.element) { i, _ in
                    FloatingHeart(delay: Double(i) * 0.1).offset(y: -size * 0.9)
                }
            }
            .frame(width: size * 1.6, height: size * 1.25, alignment: .bottom)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { NotchController.current?.open(tab: .pet) }
            .onTapGesture { model.petted() }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { _ in if model.behavior != .dragged { model.beginDrag(at: NSEvent.mouseLocation) } }
                .onEnded { _ in model.endDrag() })
        }
    }

    private var animating: Bool {
        [.walking, .dragged, .falling, .happy, .eating, .sleeping, .fishing].contains(model.behavior) || !model.hearts.isEmpty
    }

    /// Little hops while walking; a gentle breath otherwise.
    private func bob(_ t: Double) -> CGFloat {
        switch model.behavior {
        case .walking: return CGFloat(abs(sin(t * 9))) * size * 0.08
        case .happy: return CGFloat(abs(sin(t * 12))) * size * 0.12
        default: return 0
        }
    }

    private func squash(_ t: Double) -> (x: CGFloat, y: CGFloat) {
        switch model.behavior {
        case .sleeping: let b = CGFloat(sin(t * 1.4)) * 0.03; return (1 + b, 0.92 - b)
        case .sitting: return (1.06, 0.92)
        case .eating: let b = CGFloat(abs(sin(t * 10))) * 0.05; return (1 + b, 1 - b)
        default: return (1, 1)
        }
    }
}

private struct FloatingHeart: View {
    let delay: Double
    @State private var up = false

    var body: some View {
        Text("❤️").font(.system(size: 14))
            .offset(y: up ? -40 : 0)
            .opacity(up ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 1.1).delay(delay)) { up = true } }
    }
}

// MARK: - Pet Room (island tab)

struct PetTab: View {
    enum Section: String, CaseIterable { case care = "Care", fishing = "Fishing", memories = "Memories", collection = "Collection" }
    @ObservedObject private var pet = AppState.shared.pet
    @State private var section: Section = .care
    @AppStorage(Pref.petSpecies.rawValue) private var species = "🐱"
    @AppStorage(Pref.petHue.rawValue) private var hue = 0.0
    @AppStorage(Pref.petEnabled.rawValue) private var enabled = true

    var body: some View {
        HStack(spacing: Layout.gap) {
            VStack(spacing: 6) {
                Text(species).font(.system(size: 48)).hueRotation(.degrees(hue))
                    .overlay(alignment: .top) {
                        if let hat = PetOutfits.headwear(sleeping: pet.isSleeping) { Text(hat).font(.system(size: 18)).offset(y: -14) }
                    }
                Text(pet.name).font(.system(size: 13, weight: .bold))
                Text("\(pet.personality.title) · \(pet.age) day\(pet.age == 1 ? "" : "s") old").font(.system(size: 10)).foregroundStyle(.secondary)
                if !enabled {
                    Button("Show on desktop") { enabled = true }.font(.caption).buttonStyle(.plain).foregroundStyle(.blue)
                }
            }
            .frame(width: 130)
            .frame(maxHeight: .infinity)
            .background(cardBackground)

            VStack(spacing: 8) {
                Picker("", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Group {
                    switch section {
                    case .care: care
                    case .fishing: fishingView
                    case .memories: memories
                    case .collection: collection
                    }
                }
                .padding(Layout.card)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(cardBackground)
            }
        }
        .font(.system(size: 12))
    }

    private var care: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                meter("Fullness", pet.data.fullness, .orange, "fork.knife")
                meter("Happiness", pet.data.happiness, .pink, "heart.fill")
                meter("Energy", pet.data.energy, .green, "bolt.fill")
            }
            LazyVGrid(columns: [GridItem(.fixed(84), spacing: 6), GridItem(.fixed(84), spacing: 6)], spacing: 6) {
                action("fork.knife", "Feed") { pet.feed() }
                action("hand.raised.fill", "Pet") { pet.petted() }
                action("figure.play", "Play") { pet.play() }
                action(pet.isSleeping ? "sun.max.fill" : "moon.zzz.fill", pet.isSleeping ? "Wake" : "Nap") { pet.toggleSleep() }
            }
        }
    }

    private func meter(_ title: String, _ value: Double, _ color: Color, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 11))
                Spacer()
                Text("\(Int(value * 100))%").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: value).tint(color)
        }
    }

    private func action(_ icon: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 14))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(width: 84, height: 44)
            .adaptiveGlass(.clear.interactive(), in: .rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(BouncyButtonStyle())
    }

    private var fishingView: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.blue.opacity(0.25))
                Text(fishIcon).font(.system(size: 34))
                    .scaleEffect(pet.fishing == .bite ? 1.25 : 1)
                    .animation(.spring(response: 0.2, dampingFraction: 0.4), value: pet.fishing)
            }
            .frame(width: 92, height: 92)
            VStack(alignment: .leading, spacing: 8) {
                Text(fishStatus).font(.system(size: 13, weight: .semibold))
                Text("Cast, wait for the splash, then reel in fast.").font(.caption).foregroundStyle(.secondary)
                Button(pet.fishing == .waiting || pet.fishing == .bite ? "Reel in!" : "Cast line") { pet.reel() }
                    .buttonStyle(BouncyButtonStyle())
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .adaptiveGlass(GlassSpec.regular.tint((pet.fishing == .bite ? Color.green : Color.blue).opacity(0.45)).interactive(), in: .capsule)
                    .keyboardShortcut(.space, modifiers: [])
            }
        }
    }

    private var fishIcon: String {
        switch pet.fishing {
        case .idle: return "🎣"
        case .waiting: return "🌊"
        case .bite: return "💦"
        case .caught(let f): return f
        case .missed: return "🫧"
        }
    }

    private var fishStatus: String {
        switch pet.fishing {
        case .idle: return "Gone fishing?"
        case .waiting: return "Waiting for a bite…"
        case .bite: return "Something's biting!"
        case .caught(let f): return "Caught \(PetCatalog.fish.first { $0.emoji == f }?.name.lowercased() ?? "something")!"
        case .missed: return "It got away"
        }
    }

    private var memories: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pet.data.memories) { m in
                    HStack(spacing: 8) {
                        Image(systemName: m.icon).foregroundStyle(.pink).frame(width: 16)
                        Text(m.text).lineLimit(1)
                        Spacer()
                        Text(m.date.formatted(.dateTime.month(.abbreviated).day())).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.trailing, 8)
        }
        .scrollIndicators(.never)
    }

    private var collection: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 8) {
            ForEach(PetCatalog.fish, id: \.emoji) { f in
                let count = pet.data.catches[f.emoji] ?? 0
                VStack(spacing: 2) {
                    Text(count > 0 ? f.emoji : "❔").font(.system(size: 20)).opacity(count > 0 ? 1 : 0.4)
                    Text(count > 0 ? "×\(count)" : "—").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .help(count > 0 ? f.name : "Not caught yet")
            }
        }
    }
}
