import AppKit
import AVFoundation
import IOKit.hid

/// Knock to Control: single / double / triple knocks run actions.
/// Detection: the microphone (knock on the desk or case — any Mac), the accelerometer
/// (Apple Silicon MacBooks), or double-tapping a modifier key.
@MainActor
final class KnockModel: ObservableObject {
    enum Action: String, CaseIterable, Identifiable {
        case none, toggleIsland, shelf, clipboard, keepAwake, playPause, nextTrack, muteMic, screenshot, palette
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "Nothing"
            case .toggleIsland: return "Open / close island"
            case .shelf: return "Open Shelf"
            case .clipboard: return "Open Clipboard"
            case .keepAwake: return "Toggle Keep Awake"
            case .playPause: return "Play / Pause"
            case .nextTrack: return "Next track"
            case .muteMic: return "Mute microphone"
            case .screenshot: return "Screenshot selection"
            case .palette: return "Command palette"
            }
        }
    }

    enum Method: String, CaseIterable, Identifiable {
        case microphone, accelerometer, key
        var id: String { rawValue }
        var title: String {
            switch self {
            case .microphone: return "Microphone (knock on desk or case)"
            case .accelerometer: return "Accelerometer (Apple Silicon MacBooks)"
            case .key: return "Double-tap a key"
            }
        }
    }

    static let keys: [(name: String, code: UInt16, flag: NSEvent.ModifierFlags)] = [
        ("Right Option", 61, .option), ("Right Command", 54, .command), ("Right Shift", 60, .shift),
        ("Left Control", 59, .control), ("Fn", 63, .function),
    ]

    @Published private(set) var running = false
    @Published private(set) var level: Float = 0
    @Published private(set) var status = ""

    private var engine: AVAudioEngine?
    private var detector: TransientDetector?
    private var accelerometer: AccelerometerKnock?
    private var monitors: [Any] = []
    private var knocks: [Date] = []
    private var pending: DispatchWorkItem?
    private var lastTyping = Date.distantPast
    private var lastClick = Date.distantPast
    private var generation = 0

    func apply() {
        stop()
        guard Pref.knockEnabled.bool else { return }
        let method = Method(rawValue: Pref.knockMethod.string) ?? .microphone
        switch method {
        case .microphone: startMicrophone()
        case .accelerometer: startAccelerometer()
        case .key: startKey()
        }
        if Pref.typingProtection.bool, method != .key {
            // Typing makes sharp sounds/vibrations; ignore knocks right after keystrokes.
            if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.lastTyping = Date() }
            }) { monitors.append(m) }
        }
        if Pref.knockIgnoreClicks.bool, method != .key {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel], handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.lastClick = Date() }
            }) { monitors.append(m) }
        }
    }

    func stop() {
        generation += 1
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        detector = nil
        accelerometer?.stop()
        accelerometer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        running = false
    }

    // MARK: Detection

    private func startMicrophone() {
        let gen = generation
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard gen == self.generation, Pref.knockEnabled.bool else { return }
                guard granted else { self.status = "Microphone access denied"; return }
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0 else { self.status = "No microphone"; return }
                let detector = TransientDetector(sensitivity: Float(Pref.knockSensitivity.double)) { [weak self] in
                    Task { @MainActor in self?.registerKnock() }
                } onLevel: { [weak self] level in
                    Task { @MainActor in self?.level = level }
                }
                input.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in detector.process(buffer) }
                do {
                    try engine.start()
                    self.engine = engine
                    self.detector = detector
                    self.running = true
                    self.status = "Listening for knocks"
                } catch {
                    self.status = "Couldn't start the microphone"
                }
            }
        }
    }

    private func startAccelerometer() {
        let accel = AccelerometerKnock(sensitivity: Pref.knockSensitivity.double) { [weak self] in
            Task { @MainActor in self?.registerKnock() }
        }
        if accel.start() {
            accelerometer = accel
            running = true
            status = "Listening to the accelerometer"
        } else {
            status = "No accelerometer found (Apple Silicon MacBooks only)"
        }
    }

    private func startKey() {
        guard let key = Self.keys.first(where: { $0.name == Pref.knockKey.string }) ?? Self.keys.first else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == key.code, event.modifierFlags.contains(key.flag) else { return }
            MainActor.assumeIsolated { self?.registerKnock() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) { monitors.append(l) }
        running = true
        status = "Tap \(key.name) quickly"
    }

    // MARK: Patterns

    private func registerKnock() {
        let now = Date()
        if Pref.typingProtection.bool, now.timeIntervalSince(lastTyping) < 0.5 { return }
        if Pref.knockIgnoreClicks.bool, now.timeIntervalSince(lastClick) < 0.5 { return }
        knocks.append(now)
        pending?.cancel()
        // Wait briefly for further knocks, then act on the count.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let count = self.knocks.count
                self.knocks = []
                self.perform(count: count)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func perform(count: Int) {
        // A key "knock" mode never uses single taps — every modifier press would trigger it.
        let method = Method(rawValue: Pref.knockMethod.string) ?? .microphone
        let key: Pref = count >= 3 ? .knockTriple : count == 2 ? .knockDouble : .knockSingle
        if method == .key, count < 2 { return }
        Self.run(Action(rawValue: key.string) ?? .none)
    }

    static func run(_ action: Action) {
        let s = AppState.shared
        let notch = NotchController.current
        switch action {
        case .none: return
        case .toggleIsland: notch?.toggle()
        case .shelf: notch?.open(tab: .shelf)
        case .clipboard: notch?.open(tab: .clipboard)
        case .keepAwake: s.keepAwake.toggle()
        case .playPause: s.nowPlaying.togglePlayPause()
        case .nextTrack: s.nowPlaying.next()
        case .muteMic: s.audio.toggleMic()
        case .screenshot: ScreenCapture.capture(.selectionToClipboard)
        case .palette: notch?.openCommandPalette()
        }
    }
}

/// Finds sharp, short transients (a knuckle on wood/aluminium) in microphone audio.
final class TransientDetector: @unchecked Sendable {
    private let onKnock: @Sendable () -> Void
    private let onLevel: @Sendable (Float) -> Void
    private let threshold: Float
    private var background: Float = 0.01
    private var lastKnock: Double = 0
    private var levelCounter = 0

    init(sensitivity: Float, onKnock: @escaping @Sendable () -> Void, onLevel: @escaping @Sendable (Float) -> Void) {
        // sensitivity 0…1 → peak threshold 0.5…0.04
        threshold = 0.5 - 0.46 * min(max(sensitivity, 0), 1)
        self.onKnock = onKnock
        self.onLevel = onLevel
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var peak: Float = 0, sum: Float = 0
        for i in 0..<n {
            let v = abs(data[i])
            peak = max(peak, v)
            sum += v * v
        }
        let rms = (sum / Float(max(n, 1))).squareRoot()
        let now = CFAbsoluteTimeGetCurrent()
        // A knock is loud, much louder than the recent background, and far above its own RMS (short attack).
        if peak > threshold, peak > background * 6, peak > rms * 3, now - lastKnock > 0.09 {
            lastKnock = now
            onKnock()
        }
        background = background * 0.97 + rms * 0.03
        levelCounter += 1
        if levelCounter % 8 == 0 { onLevel(peak) }
    }
}

/// Apple Silicon MacBooks expose the motion sensor as a vendor HID device (AppleSPUHIDDevice).
/// Reports carry x/y/z as little-endian Int32 in 1/65536 g. Untested on Intel Macs, which have no such sensor.
final class AccelerometerKnock: @unchecked Sendable {
    private let onKnock: @Sendable () -> Void
    private let threshold: Double
    private var manager: IOHIDManager?
    private let report = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var baseline: Double = 1
    private var lastKnock: Double = 0

    init(sensitivity: Double, onKnock: @escaping @Sendable () -> Void) {
        threshold = 0.25 - 0.22 * min(max(sensitivity, 0), 1) // g deviation
        self.onKnock = onKnock
    }

    func start() -> Bool {
        // Ask the sensor driver to start reporting.
        let matching = IOServiceMatching("AppleSPUHIDDriver")
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS {
            var service = IOIteratorNext(iterator)
            while service != 0 {
                IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
                IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, 1 as CFNumber)
                IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, 1000 as CFNumber)
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 3] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return false }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            setReporting(false)
            return false
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        // IOHID keeps writing into this buffer, so it must stay at a fixed address (not a Swift array).
        IOHIDDeviceRegisterInputReportCallback(device, report, 64, { context, _, _, _, _, bytes, length in
            guard let context else { return }
            Unmanaged<AccelerometerKnock>.fromOpaque(context).takeUnretainedValue().handle(bytes, length)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
        return true
    }

    func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            setReporting(false)
        }
        manager = nil
    }

    deinit {
        stop()
        report.deallocate()
    }

    /// Turns the sensor's 1 kHz reporting on or off.
    private func setReporting(_ on: Bool) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS else { return }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, (on ? 1 : 0) as CFNumber)
            IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, (on ? 1 : 0) as CFNumber)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)
    }

    private func handle(_ bytes: UnsafeMutablePointer<UInt8>, _ length: CFIndex) {
        guard length >= 18 else { return }
        func axis(_ offset: Int) -> Double {
            let raw = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            return Double(Int32(bitPattern: raw)) / 65536
        }
        let x = axis(6), y = axis(10), z = axis(14)
        let magnitude = (x * x + y * y + z * z).squareRoot()
        let now = CFAbsoluteTimeGetCurrent()
        if abs(magnitude - baseline) > threshold, now - lastKnock > 0.09 {
            lastKnock = now
            onKnock()
        }
        baseline = baseline * 0.98 + magnitude * 0.02
    }
}
