import AppKit
import AVFoundation
import SwiftUI

// MARK: - Focus sounds (generated live — no audio files)

/// Rain, brown noise, wind and waves synthesised sample by sample.
final class NoiseGenerator: @unchecked Sendable {
    let kind: String
    private let sampleRate: Double
    private var brown: Float = 0
    private var pink: (Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0)
    private var lowpass: Float = 0
    private var drop: Float = 0
    private var phase: Double = 0
    private var rng = SystemRandomNumberGenerator()

    init(kind: String, sampleRate: Double) {
        self.kind = kind
        self.sampleRate = sampleRate
    }

    private func white() -> Float { Float.random(in: -1...1, using: &rng) }

    /// Paul Kellet's pink noise filter.
    private func pinkNoise() -> Float {
        let w = white()
        pink.0 = 0.99886 * pink.0 + w * 0.0555179
        pink.1 = 0.99332 * pink.1 + w * 0.0750759
        pink.2 = 0.96900 * pink.2 + w * 0.1538520
        pink.3 = 0.86650 * pink.3 + w * 0.3104856
        pink.4 = 0.55000 * pink.4 + w * 0.5329522
        pink.5 = -0.7616 * pink.5 - w * 0.0168980
        let out = pink.0 + pink.1 + pink.2 + pink.3 + pink.4 + pink.5 + pink.6 + w * 0.5362
        pink.6 = w * 0.115926
        return out * 0.11
    }

    private func brownNoise() -> Float {
        brown = (brown + 0.02 * white()) / 1.02
        return brown * 3.5
    }

    func sample() -> Float {
        phase += 1 / sampleRate
        switch kind {
        case "brown":
            return brownNoise()
        case "rain":
            // A bed of pink noise plus random bright droplets.
            if Float.random(in: 0...1, using: &rng) < 0.0006 { drop = Float.random(in: 0.2...0.9, using: &rng) }
            let w = white()
            lowpass += 0.6 * (w - lowpass)
            let droplet = (w - lowpass) * drop
            drop *= 0.992
            return pinkNoise() * 0.7 + droplet * 0.6
        case "wind":
            // Low-passed noise whose brightness and loudness drift slowly.
            let gust = 0.5 + 0.5 * sin(2 * .pi * phase / 9) * sin(2 * .pi * phase / 23)
            let cutoff = Float(0.01 + 0.05 * gust)
            lowpass += cutoff * (white() - lowpass)
            return lowpass * Float(2.5 + 3 * gust)
        case "waves":
            // Brown noise swelling and receding every ~8 seconds.
            let swell = pow(sin(.pi * phase / 8), 2)
            return brownNoise() * Float(0.25 + 0.85 * swell)
        default:
            return 0
        }
    }
}

@MainActor
final class FocusSoundsModel: ObservableObject {
    static let kinds = [("none", "Off"), ("rain", "Rain"), ("brown", "Brown noise"), ("wind", "Wind"), ("waves", "Waves")]
    @Published private(set) var playing: String?
    private var engine: AVAudioEngine?
    private var configObserver: Any?

    func apply() {
        let kind = Pref.focusSound.string
        if kind == playing { engine?.mainMixerNode.outputVolume = Float(Pref.focusSoundVolume.double); return }
        stop()
        guard kind != "none" else { return }
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let left = NoiseGenerator(kind: kind, sampleRate: 44_100)
        let right = NoiseGenerator(kind: kind, sampleRate: 44_100)
        let node = AVAudioSourceNode(format: format) { _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for f in 0..<Int(frames) {
                let l = left.sample(), r = right.sample()
                for (i, b) in buffers.enumerated() {
                    b.mData?.assumingMemoryBound(to: Float.self)[f] = i == 0 ? l : r
                }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = Float(Pref.focusSoundVolume.double)
        do {
            try engine.start()
            self.engine = engine
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stop()
                    self?.apply()
                }
            }
            playing = kind
        } catch {
            AppState.shared.hud.show(icon: "exclamationmark.triangle", text: "Couldn't play focus sounds")
        }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.stop()
        engine = nil
        playing = nil
    }
}

// MARK: - Typing sounds

@MainActor
final class TypingSoundsModel {
    private var configObserver: Any?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var buffers: [AVAudioPCMBuffer] = []
    private var monitor: Any?

    func apply() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        engine?.stop()
        engine = nil
        guard Pref.typingSounds.bool else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        buffers = (0..<4).map { Self.click(style: Pref.typingSoundStyle.string, format: format, variant: $0) }
        guard (try? engine.start()) != nil else { return }
        player.play()
        self.engine = engine
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        self.player = player
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !event.isARepeat else { return }
            MainActor.assumeIsolated {
                guard let self, let player = self.player, let buffer = self.buffers.randomElement() else { return }
                player.scheduleBuffer(buffer, at: nil, options: [])
            }
        }
    }

    /// A short synthesised key click: a noise burst plus a low "thock" (mechanical) or a sharp tick (typewriter).
    private static func click(style: String, format: AVAudioFormat, variant: Int) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate * 0.05)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        let typewriter = style == "typewriter"
        let pitch = (typewriter ? 2400.0 : 180.0) * (1 + Double(variant) * 0.06)
        for i in 0..<Int(frames) {
            let t = Double(i) / format.sampleRate
            let noise = Float.random(in: -1...1) * Float(exp(-t * (typewriter ? 260 : 180)))
            let body = Float(sin(2 * .pi * pitch * t) * exp(-t * (typewriter ? 120 : 60)))
            data[i] = (noise * 0.5 + body * (typewriter ? 0.25 : 0.6)) * 0.5
        }
        return buffer
    }
}

// MARK: - Cursor effects (click ripples, halo, spotlight)

@MainActor
final class CursorEffects: ObservableObject {
    struct Ripple: Identifiable { let id = UUID(); let point: CGPoint; let date: Date; let right: Bool }
    @Published private(set) var ripples: [Ripple] = []
    @Published private(set) var spotlight = false
    private var windows: [NSWindow] = []
    private var monitors: [Any] = []

    func apply() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard Pref.cursorEffect.string != "none" else { return }
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.sharingType = .readOnly
            w.contentView = NSHostingView(rootView: CursorEffectView(model: self, screenFrame: screen.frame))
            w.orderFrontRegardless()
            windows.append(w)
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
            MainActor.assumeIsolated { self?.click(right: e.type == .rightMouseDown) }
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            // Hold ⌃⌥ to spotlight the pointer.
            let on = e.modifierFlags.contains([.control, .option])
            MainActor.assumeIsolated { self?.spotlight = on }
        } as Any)
    }

    private func click(right: Bool) {
        guard ["ripple", "spotlight"].contains(Pref.cursorEffect.string) else { return }
        ripples.append(Ripple(point: NSEvent.mouseLocation, date: Date(), right: right))
        // Drop finished ripples so the overlay can stop redrawing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            MainActor.assumeIsolated { self?.ripples.removeAll { Date().timeIntervalSince($0.date) > 0.6 } }
        }
    }
}

private struct CursorEffectView: View {
    @ObservedObject var model: CursorEffects
    let screenFrame: CGRect
    @AppStorage(Pref.cursorEffect.rawValue) private var effect = "none"

    var body: some View {
        TimelineView(.animation(paused: model.ripples.isEmpty && !model.spotlight && effect != "halo")) { ctx in
            let m = NSEvent.mouseLocation
            let p = CGPoint(x: m.x - screenFrame.minX, y: screenFrame.maxY - m.y)
            ZStack {
                if effect == "spotlight" && model.spotlight {
                    Rectangle().fill(.black.opacity(0.55))
                        .mask(Rectangle().overlay(Circle().frame(width: 220, height: 220).position(p).blendMode(.destinationOut)).compositingGroup())
                }
                if effect == "halo" {
                    Circle().fill(Color.yellow.opacity(0.25)).frame(width: 46, height: 46).position(p)
                }
                ForEach(model.ripples) { r in
                    let age = ctx.date.timeIntervalSince(r.date)
                    if age < 0.6 {
                        Circle().stroke(r.right ? Color.blue : Color.orange, lineWidth: 3)
                            .frame(width: 20 + age * 90, height: 20 + age * 90)
                            .opacity(1 - age / 0.6)
                            .position(x: r.point.x - screenFrame.minX, y: screenFrame.maxY - r.point.y)
                    }
                }
            }
            .frame(width: screenFrame.width, height: screenFrame.height)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Rounded screen corners

@MainActor
final class ScreenCorners {
    private var windows: [NSWindow] = []

    func apply() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        guard Pref.blackCorners.bool else { return }
        let r = CGFloat(Pref.cornerRadius.double)
        for screen in NSScreen.screens {
            let f = screen.frame
            let corners: [(CGPoint, Int)] = [(CGPoint(x: f.minX, y: f.maxY - r), 0), (CGPoint(x: f.maxX - r, y: f.maxY - r), 1),
                                             (CGPoint(x: f.minX, y: f.minY), 2), (CGPoint(x: f.maxX - r, y: f.minY), 3)]
            for (origin, which) in corners {
                let w = NSWindow(contentRect: NSRect(origin: origin, size: CGSize(width: r, height: r)), styleMask: .borderless, backing: .buffered, defer: false)
                w.isOpaque = false
                w.backgroundColor = .clear
                w.ignoresMouseEvents = true
                w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
                w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                w.contentView = NSHostingView(rootView: CornerShape(corner: which).fill(Color.black).frame(width: r, height: r))
                w.orderFrontRegardless()
                windows.append(w)
            }
        }
    }

    private struct CornerShape: Shape {
        let corner: Int // 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right

        func path(in rect: CGRect) -> Path {
            var p = Path(rect)
            let center: CGPoint
            switch corner {
            case 0: center = CGPoint(x: rect.maxX, y: rect.maxY)
            case 1: center = CGPoint(x: rect.minX, y: rect.maxY)
            case 2: center = CGPoint(x: rect.maxX, y: rect.minY)
            default: center = CGPoint(x: rect.minX, y: rect.minY)
            }
            p.addEllipse(in: CGRect(x: center.x - rect.width, y: center.y - rect.height, width: rect.width * 2, height: rect.height * 2))
            return p
        }

        func fill(_ color: Color) -> some View { self.fill(color, style: FillStyle(eoFill: true)) }
    }
}

// MARK: - Clean Screen (black-out to wipe the display)

@MainActor
enum CleanScreen {
    private static var windows: [NSWindow] = []
    private static var monitor: Any?

    static func start() {
        stop()
        for screen in NSScreen.screens {
            let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.backgroundColor = .black
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = NSHostingView(rootView:
                Text("Wipe away — press Esc or hold the mouse to exit")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.25))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(40)
                    .onLongPressGesture(minimumDuration: 1) { stop() })
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        NSApp.activate()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { MainActor.assumeIsolated { stop() }; return nil }
            return nil
        }
    }

    static func stop() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }
}

// MARK: - Display tweaks: software dim, colour temperature, refresh rate

@MainActor
final class DisplayTweaks: ObservableObject {
    @Published var dims: [String: Double] = (UserDefaults.standard.dictionary(forKey: "softwareDim") as? [String: Double]) ?? [:] {
        didSet { UserDefaults.standard.set(dims, forKey: "softwareDim"); applyDim() }
    }
    private var dimWindows: [String: NSWindow] = [:]

    /// Name plus display number, so two identical monitors get separate settings.
    static func key(_ screen: NSScreen) -> String {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        return "\(screen.localizedName)#\(id)"
    }

    /// A dark overlay for monitors that don't support DDC brightness.
    func applyDim() {
        let connected = Set(NSScreen.screens.map(Self.key))
        for (key, w) in dimWindows where !connected.contains(key) {
            w.orderOut(nil)
            dimWindows[key] = nil
        }
        for screen in NSScreen.screens {
            let name = Self.key(screen)
            let level = dims[name] ?? 0
            if level <= 0.01 {
                dimWindows[name]?.orderOut(nil)
                dimWindows[name] = nil
                continue
            }
            let w = dimWindows[name] ?? {
                let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                w.ignoresMouseEvents = true
                w.level = .screenSaver
                w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                w.isOpaque = false
                w.sharingType = .none
                w.orderFrontRegardless()
                return w
            }()
            w.setFrame(screen.frame, display: false)
            w.backgroundColor = NSColor.black.withAlphaComponent(level * 0.85)
            dimWindows[name] = w
        }
    }

    /// Warms or cools every display by scaling its gamma curve (6500 K = neutral).
    func applyTemperature() {
        let k = Pref.colorTemperature.double
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        guard abs(k - 6500) > 50 else { CGDisplayRestoreColorSyncSettings(); return }
        let (r, g, b) = Self.rgb(kelvin: k)
        for id in ids.prefix(Int(count)) {
            CGSetDisplayTransferByFormula(id, 0, CGGammaValue(r), 1, 0, CGGammaValue(g), 1, 0, CGGammaValue(b), 1)
        }
    }

    /// Tanner Helland's black-body approximation, normalised so 6500 K is white.
    static func rgb(kelvin: Double) -> (Double, Double, Double) {
        func raw(_ k: Double) -> (Double, Double, Double) {
            let t = k / 100
            let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
            let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
            let b = t >= 66 ? 255 : t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
            return (min(max(r, 0), 255) / 255, min(max(g, 0), 255) / 255, min(max(b, 0), 255) / 255)
        }
        let c = raw(kelvin), w = raw(6500)
        return (min(c.0 / w.0, 1), min(c.1 / w.1, 1), min(c.2 / w.2, 1))
    }

    struct RefreshOption: Hashable { let rate: Double; let mode: CGDisplayMode }

    /// Refresh rates available at the display's current resolution.
    static func refreshRates(_ display: CGDirectDisplayID) -> (current: Double, options: [RefreshOption]) {
        guard let current = CGDisplayCopyDisplayMode(display),
              let modes = CGDisplayCopyAllDisplayModes(display, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] else {
            return (0, [])
        }
        var seen = Set<Int>()
        let options = modes.filter {
            $0.width == current.width && $0.height == current.height && $0.pixelWidth == current.pixelWidth && $0.refreshRate > 0
        }.sorted { $0.refreshRate > $1.refreshRate }.compactMap { m -> RefreshOption? in
            seen.insert(Int(m.refreshRate.rounded())).inserted ? RefreshOption(rate: m.refreshRate, mode: m) : nil
        }
        return (current.refreshRate, options)
    }

    static func setRefresh(_ display: CGDirectDisplayID, _ option: RefreshOption) {
        CGDisplaySetDisplayMode(display, option.mode, nil)
    }
}

// MARK: - Screen light (a soft ring light around the screen edges for video calls)

@MainActor
final class ScreenLight: ObservableObject {
    @Published private(set) var on = false
    private var windows: [NSWindow] = []
    private var autoOn = false

    func toggle() { set(!on) }

    func set(_ enabled: Bool) {
        on = enabled
        apply()
    }

    /// Called once a second: follows the camera when "turn on with the camera" is set.
    func tick() {
        guard Pref.screenLightAuto.bool else {
            if autoOn { autoOn = false; set(false) }
            return
        }
        let camera = AppState.shared.audio.cameraInUse
        if camera, !on { autoOn = true; set(true) }
        if !camera, on, autoOn { autoOn = false; set(false) }
    }

    func apply() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        guard on else { return }
        let screens = Pref.screenLightAllDisplays.bool ? NSScreen.screens : [NSScreen.main ?? NSScreen.screens[0]]
        for screen in screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true // never blocks clicks
            w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.sharingType = .none // keep it out of screen shares and recordings
            let host = NSHostingView(rootView: ScreenLightView())
            host.sizingOptions = []
            w.contentView = host
            w.setFrame(screen.frame, display: false)
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.35; w.animator().alphaValue = 1 }
            windows.append(w)
        }
        AppState.shared.hud.show(icon: "light.max", text: "Screen light on")
    }
}

private struct ScreenLightView: View {
    @AppStorage(Pref.screenLightBrightness.rawValue) private var brightness = 0.85
    @AppStorage(Pref.screenLightWarmth.rawValue) private var warmth = 0.3
    @AppStorage(Pref.screenLightWidth.rawValue) private var width = 0.12

    var body: some View {
        GeometryReader { geo in
            let band = min(geo.size.width, geo.size.height) * width
            // Warmth blends from daylight white toward a soft tungsten tone.
            let color = Color(red: 1, green: 1 - 0.12 * warmth, blue: 1 - 0.38 * warmth)
            ZStack {
                Rectangle().fill(color.opacity(brightness))
                RoundedRectangle(cornerRadius: band * 0.9, style: .continuous)
                    .padding(band)
                    .blur(radius: band * 0.35)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
