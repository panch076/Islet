import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import os

/// System-wide 3-band EQ through the Islet Audio driver: apps play into the virtual device,
/// Islet reads its loopback input, filters it, and plays it to the real speakers. Nothing reaches
/// the speakers directly, so there's no doubled (echoing) signal.
@MainActor
final class EQModel: ObservableObject {
    struct Preset { let name: String; let low: Float; let mid: Float; let high: Float }
    static let presets = [
        Preset(name: "Flat", low: 0, mid: 0, high: 0),
        Preset(name: "Bass Boost", low: 6, mid: 0, high: 1),
        Preset(name: "Vocal", low: -2, mid: 4, high: 2),
        Preset(name: "Treble", low: -1, mid: 0, high: 5),
        Preset(name: "Loudness", low: 5, mid: -1, high: 4),
    ]
    static let driverUID = "IsletAudio_UID"

    @Published private(set) var enabled = false
    @Published private(set) var error: String?
    @Published private(set) var driverInstalled = false
    @Published private(set) var realOutputName = ""
    @Published var low = UserDefaults.standard.float(forKey: "eqLow") { didSet { save() } }
    @Published var mid = UserDefaults.standard.float(forKey: "eqMid") { didSet { save() } }
    @Published var high = UserDefaults.standard.float(forKey: "eqHigh") { didSet { save() } }

    private var router: DriverRouter?
    private var switching = false

    var supported: Bool { true }

    /// UID of the speakers the EQ'd audio goes to; remembered so a crash can be undone at launch.
    private var realOutputUID: String? {
        get { UserDefaults.standard.string(forKey: "eqRealOutputUID") }
        set { UserDefaults.standard.set(newValue, forKey: "eqRealOutputUID") }
    }

    /// Looked up once a second (and on demand) instead of scanning every device on each access.
    private(set) var driverDevice: AudioDeviceID?
    private(set) var selectedOutput: AudioDeviceID?
    private var lastAliveCheck = Date.distantPast

    func refreshDevices() {
        driverDevice = CA.device(uid: Self.driverUID)
        selectedOutput = realOutputUID.flatMap(CA.device(uid:))
        if driverInstalled != (driverDevice != nil) { driverInstalled = driverDevice != nil }
    }

    /// Turns the EQ off after a failure and makes sure sound isn't left going into the driver with no one reading it.
    private func fail(_ message: String) {
        router?.stop()
        router = nil
        error = message
        enabled = false
        UserDefaults.standard.set(false, forKey: "eqEnabled")
        restoreSpeakers()
    }

    private func restoreSpeakers() {
        let current: AudioDeviceID = CA.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(0))
        guard let driver = driverDevice, current == driver else { return }
        let fallback = realOutputUID.flatMap(CA.device(uid:))
            ?? CA.devices().first { $0 != driver && CA.hasStreams($0, scope: kAudioObjectPropertyScopeOutput) && CA.name($0) != "Islet EQ" }
        if let fallback { CA.setDefaultOutput(fallback) }
    }

    func startup() {
        refreshDevices()
        if let real = selectedOutput { realOutputName = CA.name(real) }
        let systemOutput: AudioDeviceID = CA.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(0))
        if UserDefaults.standard.bool(forKey: "eqEnabled") {
            setEnabled(true)
        } else if let driver = driverDevice, systemOutput == driver, let uid = realOutputUID, let real = CA.device(uid: uid) {
            // Islet quit while routing through the driver; give the user their speakers back.
            CA.setDefaultOutput(real)
        }
    }

    func setEnabled(_ on: Bool) {
        switching = true
        defer { switching = false }
        router?.stop()
        router = nil
        error = nil
        refreshDevices()
        if !on {
            restoreSpeakers()
            enabled = false
            UserDefaults.standard.set(false, forKey: "eqEnabled")
            return
        }
        guard let driver = driverDevice else {
            fail("Install the Islet Audio driver first.")
            return
        }
        // Pick the speakers: the current output, unless that's already the driver.
        let current: AudioDeviceID = CA.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(0))
        var real = current != driver ? current : realOutputUID.flatMap(CA.device(uid:))
        if real == nil || real == driver {
            real = CA.devices().first { $0 != driver && CA.hasStreams($0, scope: kAudioObjectPropertyScopeOutput) && CA.name($0) != "Islet EQ" }
        }
        guard let real, let realUID = CA.string(real, kAudioDevicePropertyDeviceUID) else {
            fail("No speakers found")
            return
        }
        realOutputUID = realUID
        realOutputName = CA.name(real)

        let router = DriverRouter()
        if let failure = router.start(driver: driver, output: real) {
            fail(failure)
            return
        }
        self.router = router
        CA.setDefaultOutput(driver)
        enabled = true
        UserDefaults.standard.set(true, forKey: "eqEnabled")
        apply()
    }

    /// On quit: hand the speakers back but remember the EQ was on, so it resumes next launch.
    func shutdown() {
        guard enabled else { return }
        router?.stop()
        router = nil
        if let uid = realOutputUID, let real = CA.device(uid: uid) { CA.setDefaultOutput(real) }
    }

    /// While the EQ runs, picking speakers changes where the EQ'd audio goes.
    func route(to device: AudioDeviceID) {
        guard let uid = CA.string(device, kAudioDevicePropertyDeviceUID) else { return }
        realOutputUID = uid
        realOutputName = CA.name(device)
        selectedOutput = device
        if enabled { setEnabled(true) }
        AppState.shared.hud.show(icon: "hifispeaker.fill", text: "EQ plays through \(realOutputName)")
    }

    /// Speakers the EQ can play through (everything except the driver itself).
    var outputChoices: [AudioDevice] {
        let driver = driverDevice
        return AppState.shared.audio.outputs.filter { $0.id != driver }
    }


    /// Called with the system output each tick: if the user picks other speakers in macOS, step aside.
    func outputChanged(to id: AudioDeviceID) {
        if enabled, !switching, Date().timeIntervalSince(lastAliveCheck) > 2 {
            lastAliveCheck = Date()
            if router?.isAlive != true {
                refreshDevices()
                setEnabled(true)
                return
            }
        }
        guard enabled, !switching, let driver = driverDevice, id != 0, id != driver else { return }
        router?.stop()
        router = nil
        enabled = false
        UserDefaults.standard.set(false, forKey: "eqEnabled")
    }

    func applyPreset(_ p: Preset) {
        low = p.low; mid = p.mid; high = p.high
    }

    func installDriver() {
        // coreaudiod restarts during install; route around the driver first, then resume.
        let wasOn = enabled
        if wasOn { setEnabled(false) }
        resumeAfterInstall = wasOn
        guard let bundle = Bundle.main.resourceURL?.appendingPathComponent("IsletAudio.driver"),
              FileManager.default.fileExists(atPath: bundle.path) else {
            error = "Driver missing from the app bundle — rebuild with build.sh"
            return
        }
        let dst = "/Library/Audio/Plug-Ins/HAL/IsletAudio.driver"
        let command = "mkdir -p /Library/Audio/Plug-Ins/HAL && rm -rf \(Self.quoted(dst)) && cp -R \(Self.quoted(bundle.path)) \(Self.quoted(dst)) && chown -R root:wheel \(Self.quoted(dst)) && (launchctl kickstart -k system/com.apple.audio.coreaudiod || killall coreaudiod)"
        runPrivileged(command, success: "Islet Audio driver installed")
    }

    func uninstallDriver() {
        setEnabled(false)
        runPrivileged("rm -rf /Library/Audio/Plug-Ins/HAL/IsletAudio.driver && (launchctl kickstart -k system/com.apple.audio.coreaudiod || killall coreaudiod)",
                      success: "Islet Audio driver removed")
    }

    /// Runs a shell command as root after macOS asks for the administrator password.
    private var resumeAfterInstall = false

    /// Single-quotes a path for the shell, escaping any single quotes inside it.
    static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func runPrivileged(_ command: String, success: String) {
        // AppleScript string literal: escape backslashes first, then double quotes.
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(literal)\" with administrator privileges"
        DispatchQueue.global().async {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            Task { @MainActor in
                if let err {
                    self.error = (err[NSAppleScript.errorMessage] as? String) ?? "Cancelled"
                } else {
                    AppState.shared.hud.show(icon: "checkmark.seal.fill", text: success, seconds: 3)
                    // coreaudiod takes a moment to come back with the new device.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.refreshDevices()
                        if self.resumeAfterInstall { self.resumeAfterInstall = false; self.setEnabled(true) }
                    }
                }
            }
        }
    }

    private func save() {
        UserDefaults.standard.set(low, forKey: "eqLow")
        UserDefaults.standard.set(mid, forKey: "eqMid")
        UserDefaults.standard.set(high, forKey: "eqHigh")
        apply()
    }

    private func apply() {
        guard let router else { return }
        router.processor.configure(sampleRate: router.sampleRate, low: low, mid: mid, high: high)
    }
}

/// An aggregate of [Islet Audio, speakers]: reads the driver's loopback input, writes the speakers.
final class DriverRouter {
    let processor = EQProcessor()
    private(set) var sampleRate: Double = 48_000
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "islet.eq", qos: .userInteractive)

    /// Returns an error message, or nil on success.
    func start(driver: AudioDeviceID, output: AudioDeviceID) -> String? {
        guard let driverUID = CA.string(driver, kAudioDevicePropertyDeviceUID),
              let outputUID = CA.string(output, kAudioDevicePropertyDeviceUID) else { return "Audio devices unavailable" }

        // Match the driver's rate to the speakers so no resampling is needed.
        let rate: Float64 = CA.get(output, kAudioDevicePropertyNominalSampleRate, default: Float64(48_000))
        CA.set(driver, kAudioDevicePropertyNominalSampleRate, value: rate)
        sampleRate = rate

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Islet EQ",
            kAudioAggregateDeviceUIDKey: "IsletEQ_" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: driverUID, kAudioSubDeviceDriftCompensationKey: true],
                [kAudioSubDeviceUIDKey: outputUID],
            ],
        ]
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID) == noErr else {
            return "Couldn't create the EQ audio device"
        }

        // The driver comes first in the aggregate: its 2 loopback inputs are channels 0–1, and its own
        // 2 outputs are output channels 0–1, which must stay silent or the audio would loop forever.
        processor.inputLimit = 2
        processor.outputSkip = 2
        processor.reset()
        let processor = self.processor
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { _, input, _, output, _ in
            processor.process(input, output)
        }
        guard status == noErr, let proc else {
            stop()
            return "Couldn't start the EQ"
        }
        procID = proc
        guard AudioDeviceStart(aggregateID, proc) == noErr else {
            stop()
            return "Couldn't start the EQ"
        }
        return nil
    }

    /// False once coreaudiod restarts (the private aggregate is gone) or after stop().
    var isAlive: Bool {
        aggregateID != kAudioObjectUnknown && CA.get(aggregateID, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0)) != 0
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}

/// Low shelf (105 Hz), peak (1 kHz), high shelf (7.5 kHz) biquads, RBJ cookbook.
final class EQProcessor: @unchecked Sendable {
    struct Coeffs { var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0 }

    /// Only the first `inputLimit` input channels are the signal; the first `outputSkip` outputs are muted.
    var inputLimit = Int.max
    var outputSkip = 0

    struct Bank { var c0 = Coeffs(), c1 = Coeffs(), c2 = Coeffs(); var bypass = true }
    private let bank = OSAllocatedUnfairLock(initialState: Bank())
    private static let maxChannels = 16
    /// Per channel, per band: x1, x2, y1, y2.
    private let state = UnsafeMutablePointer<Float>.allocate(capacity: maxChannels * 12)

    init() { state.initialize(repeating: 0, count: Self.maxChannels * 12) }
    deinit { state.deallocate() }

    func reset() { state.update(repeating: 0, count: Self.maxChannels * 12) }

    func configure(sampleRate fs: Double, low: Float, mid: Float, high: Float) {
        let b = Bank(c0: Self.shelf(low: true, f: 105, gain: low, fs: fs),
                     c1: Self.peak(f: 1000, q: 0.9, gain: mid, fs: fs),
                     c2: Self.shelf(low: false, f: 7500, gain: high, fs: fs),
                     bypass: low == 0 && mid == 0 && high == 0)
        bank.withLock { $0 = b }
    }

    /// Runs on the real-time audio thread.
    func process(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let b = bank.withLock { $0 }
        let skip = b.bypass
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        var inChannels = 0
        for b in ins { inChannels += Int(b.mNumberChannels) }
        inChannels = min(inChannels, inputLimit)

        var outIndex = 0
        for ob in outs {
            let n = Int(ob.mNumberChannels)
            defer { outIndex += n }
            guard n > 0, let od = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = Int(ob.mDataByteSize) / (MemoryLayout<Float>.size * n)
            for ch in 0..<n {
                let global = outIndex + ch - outputSkip
                guard global >= 0, inChannels > 0, let src = Self.channel(ins, global % inChannels) else {
                    for f in 0..<frames { od[f * n + ch] = 0 }
                    continue
                }
                let count = min(frames, src.frames)
                let s = state + min(global, Self.maxChannels - 1) * 12
                for f in 0..<count {
                    var x = src.data[f * src.stride]
                    if !skip {
                        x = Self.biquad(x, b.c0, s)
                        x = Self.biquad(x, b.c1, s + 4)
                        x = Self.biquad(x, b.c2, s + 8)
                    }
                    od[f * n + ch] = x
                }
                for f in count..<frames { od[f * n + ch] = 0 }
            }
        }
    }

    private static func channel(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int)
        -> (data: UnsafeMutablePointer<Float>, stride: Int, frames: Int)? {
        var base = 0
        for b in list {
            let n = Int(b.mNumberChannels)
            if index < base + n, n > 0, let d = b.mData?.assumingMemoryBound(to: Float.self) {
                return (d + (index - base), n, Int(b.mDataByteSize) / (MemoryLayout<Float>.size * n))
            }
            base += n
        }
        return nil
    }

    @inline(__always)
    private static func biquad(_ x: Float, _ c: Coeffs, _ s: UnsafeMutablePointer<Float>) -> Float {
        let y = c.b0 * x + c.b1 * s[0] + c.b2 * s[1] - c.a1 * s[2] - c.a2 * s[3]
        s[1] = s[0]; s[0] = x
        s[3] = s[2]; s[2] = y
        return y
    }

    private static func peak(f: Double, q: Double, gain: Float, fs: Double) -> Coeffs {
        let A = pow(10, Double(gain) / 40), w0 = 2 * .pi * f / fs, alpha = sin(w0) / (2 * q), cw = cos(w0)
        let a0 = 1 + alpha / A
        return Coeffs(b0: Float((1 + alpha * A) / a0), b1: Float(-2 * cw / a0), b2: Float((1 - alpha * A) / a0),
                      a1: Float(-2 * cw / a0), a2: Float((1 - alpha / A) / a0))
    }

    private static func shelf(low: Bool, f: Double, gain: Float, fs: Double) -> Coeffs {
        let A = pow(10, Double(gain) / 40), w0 = 2 * .pi * f / fs, cw = cos(w0)
        let alpha = sin(w0) / 2 * sqrt(2.0), k = 2 * sqrt(A) * alpha
        let b0, b1, b2, a0, a1, a2: Double
        if low {
            b0 = A * ((A + 1) - (A - 1) * cw + k); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - k)
            a0 = (A + 1) + (A - 1) * cw + k; a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - k
        } else {
            b0 = A * ((A + 1) + (A - 1) * cw + k); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - k)
            a0 = (A + 1) - (A - 1) * cw + k; a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - k
        }
        return Coeffs(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0), a1: Float(a1 / a0), a2: Float(a2 / a0))
    }
}
