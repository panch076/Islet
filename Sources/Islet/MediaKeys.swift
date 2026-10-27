import AppKit

/// Intercepts the volume and brightness keys so Islet's HUD replaces the system one.
/// Needs Accessibility. Keys Islet can't act on (e.g. HDMI volume) pass through untouched.
@MainActor
final class MediaKeyInterceptor {
    fileprivate static var current: MediaKeyInterceptor?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isActive: Bool { tap != nil }

    func setEnabled(_ on: Bool) {
        stop()
        guard on else { return }
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
            AppState.shared.hud.show(icon: "lock.fill", text: "Allow Islet in Accessibility settings", seconds: 3)
            return
        }
        let systemDefined = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: systemDefined, callback: mediaKeyCallback, userInfo: nil) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        Self.current = self
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns true when Islet handled the key and the system HUD should be suppressed.
    fileprivate func handle(key: Int, down: Bool, fine: Bool) -> Bool {
        let audio = AppState.shared.audio
        let player = AppState.shared.nowPlaying
        // Play/pause/next/previous go to whatever Islet is showing (Kaset, YouTube Music in a browser…).
        if Pref.mediaKeys.bool, [16, 17, 18, 19, 20].contains(key), player.canControl {
            if down {
                switch key {
                case 16: player.togglePlayPause()
                case 17, 19: player.next()
                default: player.previous()
                }
            }
            return true
        }
        guard AppState.shared.settings.replaceSystemHUD else { return false }
        switch key {
        case 0, 1: // NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN
            guard audio.hasVolumeControl else { return false }
            if down { audio.stepVolume(up: key == 0, fine: fine) }
            return true
        case 7: // NX_KEYTYPE_MUTE
            guard audio.hasVolumeControl else { return false }
            if down { audio.toggleOutputMute() }
            return true
        case 2, 3: // NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN
            if ExternalBrightness.shouldHandle {
                if down { ExternalBrightness.step(up: key == 2, fine: fine) }
                return true
            }
            guard Brightness.isAvailable else { return false }
            if down { Brightness.step(up: key == 2, fine: fine) }
            return true
        case 21, 22: // NX_KEYTYPE_ILLUMINATION_UP, NX_KEYTYPE_ILLUMINATION_DOWN
            guard KeyboardBacklight.isAvailable, let level = KeyboardBacklight.level() else { return false }
            if down {
                let step: Float = fine ? 1.0 / 64 : 1.0 / 16
                let value = min(max(level + (key == 21 ? step : -step), 0), 1)
                _ = KeyboardBacklight.setLevel(value)
                AppState.shared.hud.show(icon: "light.max", text: "\(Int(value * 100))%", progress: Double(value), seconds: 1.5)
            }
            return true
        default:
            return false
        }
    }
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { MediaKeyInterceptor.current?.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let key = (ns.data1 & 0xFFFF_0000) >> 16
    let down = ((ns.data1 & 0xFF00) >> 8) == 0x0A
    let fine = ns.modifierFlags.contains([.shift, .option])
    let handled = MainActor.assumeIsolated {
        MediaKeyInterceptor.current?.handle(key: key, down: down, fine: fine) ?? false
    }
    return handled ? nil : Unmanaged.passUnretained(event)
}

/// Built-in display brightness through the DisplayServices framework (loaded at runtime).
/// External monitors don't support it, so their keys pass through to macOS.
enum Brightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn: GetFn? = lib.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = lib.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }

    private static var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    static var isAvailable: Bool { current() != nil }

    static func current() -> Float? {
        var value: Float = 0
        guard let getFn, getFn(display, &value) == 0 else { return nil }
        return value
    }

    @MainActor
    static func step(up: Bool, fine: Bool) {
        guard let level = current(), let setFn else { return }
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        let value = min(max(level + (up ? step : -step), 0), 1)
        _ = setFn(display, value)
        AppState.shared.hud.show(icon: value < 0.5 ? "sun.min.fill" : "sun.max.fill",
                                 text: "\(Int(value * 100))%", progress: Double(value), seconds: 1.5)
    }
}

/// Brightness keys for external monitors over DDC/CI. DDC is slow (~50 ms per command), so values are
/// cached and writes happen on a background queue.
enum ExternalBrightness {
    @MainActor private static var cache: [CGDirectDisplayID: (current: Int, max: Int)] = [:]
    private static let queue = DispatchQueue(label: "islet.ddc", qos: .userInitiated)

    /// Handle the keys when the mouse is on an external display (or there's no built-in one).
    @MainActor static var shouldHandle: Bool {
        guard Pref.externalBrightness.bool, let display = target else { return false }
        return display != 0
    }

    @MainActor private static var target: CGDirectDisplayID? {
        let externals = ExternalDisplays.displays()
        guard !externals.isEmpty else { return nil }
        let mouse = NSEvent.mouseLocation
        let under = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            .flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
        if let under, externals.contains(under) { return under }
        return Brightness.isAvailable ? nil : externals.first
    }

    @MainActor static func step(up: Bool, fine: Bool) {
        guard let display = target else { return }
        guard let known = cache[display] else {
            queue.async {
                guard let read = ExternalDisplays.brightness(display) else { return }
                Task { @MainActor in
                    cache[display] = read
                    step(up: up, fine: fine)
                }
            }
            return
        }
        let delta = max(known.max / (fine ? 64 : 16), 1)
        let value = min(max(known.current + (up ? delta : -delta), 0), known.max)
        cache[display] = (value, known.max)
        let fraction = known.max > 0 ? Double(value) / Double(known.max) : 0
        AppState.shared.hud.show(icon: fraction < 0.5 ? "sun.min.fill" : "sun.max.fill", text: "\(Int(fraction * 100))%",
                                 progress: fraction, seconds: 1.5)
        queue.async { _ = ExternalDisplays.setBrightness(display, value) }
    }

    @MainActor static func set(_ display: CGDirectDisplayID, fraction: Double) {
        guard let known = cache[display] else { return }
        let value = Int((fraction * Double(known.max)).rounded())
        cache[display] = (value, known.max)
        queue.async { _ = ExternalDisplays.setBrightness(display, value) }
    }

    /// Reads current levels for the Sound tab's sliders.
    @MainActor static func load(_ done: @escaping @MainActor ([(CGDirectDisplayID, String, Double)]) -> Void) {
        let screens = NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (id, s.localizedName)
        }
        let externals = Set(ExternalDisplays.displays())
        queue.async {
            let values = screens.filter { externals.contains($0.0) }.compactMap { id, name -> (CGDirectDisplayID, String, (Int, Int))? in
                ExternalDisplays.brightness(id).map { (id, name, ($0.current, $0.max)) }
            }
            Task { @MainActor in
                for v in values { cache[v.0] = v.2 }
                done(values.map { ($0.0, $0.1, $0.2.1 > 0 ? Double($0.2.0) / Double($0.2.1) : 0) })
            }
        }
    }
}
