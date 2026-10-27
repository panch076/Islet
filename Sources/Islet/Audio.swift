import AppKit
import AudioToolbox
import CoreAudio
import CoreMediaIO

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

/// Output switching, volume, mic mute, and the camera/mic privacy indicator.
@MainActor
final class AudioModel: ObservableObject, ChangeTracking {
    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var currentOutput: AudioDeviceID = 0
    @Published private(set) var volume: Float = 0
    @Published private(set) var outputMuted = false
    @Published private(set) var micMuted = false
    @Published private(set) var micInUse = false
    @Published private(set) var cameraInUse = false

    private var lastVolume: Float?
    private var lastMuted: Bool?
    private var savedMicVolume: Float = 1

    /// Cheap; called several times a second so the volume HUD feels immediate.
    func fastTick() {
        update(\.currentOutput, to: CA.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(0)))
        update(\.volume, to: CA.volume(currentOutput, scope: kAudioObjectPropertyScopeOutput) ?? 0)
        update(\.outputMuted, to: CA.get(currentOutput, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, default: UInt32(0)) != 0)

        AppState.shared.eq.outputChanged(to: currentOutput)

        let settings = AppState.shared.settings
        if let lv = lastVolume, let lm = lastMuted, (abs(lv - volume) > 0.001 || lm != outputMuted),
           settings.volumeHUD || settings.replaceSystemHUD {
            let icon = outputMuted || volume == 0 ? "speaker.slash.fill"
                : volume < 0.33 ? "speaker.wave.1.fill" : volume < 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            AppState.shared.hud.show(icon: icon, text: "\(Int(volume * 100))%", progress: outputMuted ? 0 : Double(volume), seconds: 1.5)
        }
        lastVolume = volume
        lastMuted = outputMuted
    }

    /// Device lists and privacy state; called once a second.
    func slowTick() {
        AppState.shared.eq.refreshDevices()
        update(\.outputs, to: CA.devices().filter { CA.hasStreams($0, scope: kAudioObjectPropertyScopeOutput) }
            .map { AudioDevice(id: $0, name: CA.name($0)) }
            .filter { $0.name != "Islet EQ" && $0.id != AppState.shared.eq.driverDevice })
        let input: AudioDeviceID = CA.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, default: AudioDeviceID(0))
        update(\.micInUse, to: input != 0 && CA.get(input, kAudioDevicePropertyDeviceIsRunningSomewhere, default: UInt32(0)) != 0)
        if CA.has(input, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput) {
            update(\.micMuted, to: CA.get(input, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput, default: UInt32(0)) != 0)
        } else {
            update(\.micMuted, to: (CA.volume(input, scope: kAudioObjectPropertyScopeInput) ?? 1) == 0)
        }
        // Face presence uses the camera itself, so don't flag that as someone else watching.
        update(\.cameraInUse, to: CameraMonitor.anyCameraRunning() && !AppState.shared.presence.running)

        // Finding which app records means querying every audio process object; every 3 s is plenty.
        micScan += 1
        guard micScan % 3 == 0 || !micInUse else { return }
        let micApps = micInUse ? CA.processesUsingMic().compactMap { NSRunningApplication(processIdentifier: $0) } : []
        update(\.micAppNames, to: micApps.compactMap(\.localizedName))
        AppState.shared.calls.update(micBundleIDs: micApps.compactMap(\.bundleIdentifier))
    }

    @Published private(set) var micAppNames: [String] = []
    private var micScan = 0

    var hasVolumeControl: Bool { CA.volume(currentOutput, scope: kAudioObjectPropertyScopeOutput) != nil }

    func stepVolume(up: Bool, fine: Bool) {
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        let target = (volume / step).rounded() * step + (up ? step : -step)
        setVolume(min(max(target, 0), 1))
        fastTick()
    }

    func toggleOutputMute() {
        if CA.has(currentOutput, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput) {
            CA.set(currentOutput, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, value: UInt32(outputMuted ? 0 : 1))
        }
        fastTick()
    }

    func setOutput(_ device: AudioDevice) {
        let eq = AppState.shared.eq
        if eq.enabled, device.id != eq.driverDevice {
            eq.route(to: device.id)
            AppState.shared.hud.show(icon: "hifispeaker.fill", text: "\(device.name) · EQ on")
            return
        }
        CA.set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, value: device.id)
        CA.set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, value: device.id)
        currentOutput = device.id
        AppState.shared.hud.show(icon: "hifispeaker.fill", text: device.name)
    }

    func setVolume(_ v: Float) {
        CA.setVolume(currentOutput, scope: kAudioObjectPropertyScopeOutput, v)
        if outputMuted && v > 0 {
            CA.set(currentOutput, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, value: UInt32(0))
        }
    }

    func toggleMic() {
        let input: AudioDeviceID = CA.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, default: AudioDeviceID(0))
        guard input != 0 else { return }
        let mute = !micMuted
        if CA.has(input, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput) {
            CA.set(input, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput, value: UInt32(mute ? 1 : 0))
        } else if mute {
            savedMicVolume = max(CA.volume(input, scope: kAudioObjectPropertyScopeInput) ?? 1, 0.1)
            CA.setVolume(input, scope: kAudioObjectPropertyScopeInput, 0)
        } else {
            CA.setVolume(input, scope: kAudioObjectPropertyScopeInput, savedMicVolume)
        }
        micMuted = mute
        AppState.shared.hud.show(icon: mute ? "mic.slash.fill" : "mic.fill", text: mute ? "Mic muted" : "Mic on")
    }
}

/// Thin CoreAudio helpers.
enum CA {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var a = address(selector, scope, element)
        return obj != 0 && AudioObjectHasProperty(obj, &a)
    }

    static func get<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, default value: T) -> T {
        var a = address(selector, scope, element)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &result) == noErr ? result : value
    }

    @discardableResult
    static func set<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, value: T) -> Bool {
        var a = address(selector, scope, element)
        var v = value
        return AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }

    static func devices() -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func device(uid: String) -> AudioDeviceID? {
        devices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func setDefaultOutput(_ id: AudioDeviceID) {
        set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, value: id)
        set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, value: id)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// PIDs of processes currently recording from any input (macOS 14.2+).
    static func processesUsingMic() -> [pid_t] {
        guard #available(macOS 14.2, *) else { return [] }
        var a = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { get($0, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0 }
            .map { get($0, kAudioProcessPropertyPID, default: pid_t(0)) }
            .filter { $0 > 0 }
    }

    static func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var a = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }

    static func name(_ id: AudioDeviceID) -> String {
        var a = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name) == noErr, let name else { return "Unknown" }
        return name.takeRetainedValue() as String
    }

    /// Prefers the virtual main volume; falls back to the first channel's scalar.
    static func volume(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Float? {
        if has(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope) {
            return get(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, default: Float32(0))
        }
        for element: UInt32 in [0, 1] where has(id, kAudioDevicePropertyVolumeScalar, scope: scope, element: element) {
            return get(id, kAudioDevicePropertyVolumeScalar, scope: scope, element: element, default: Float32(0))
        }
        return nil
    }

    static func setVolume(_ id: AudioDeviceID, scope: AudioObjectPropertyScope, _ v: Float) {
        let v = Float32(min(max(v, 0), 1))
        if has(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope) {
            set(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, value: v)
            return
        }
        for element: UInt32 in [0, 1, 2] where has(id, kAudioDevicePropertyVolumeScalar, scope: scope, element: element) {
            set(id, kAudioDevicePropertyVolumeScalar, scope: scope, element: element, value: v)
        }
    }
}

enum CameraMonitor {
    static func anyCameraRunning() -> Bool {
        var a = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &a, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &a, 0, nil, size, &used, &devices) == 0 else { return false }

        a.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        return devices.contains { device in
            var running: UInt32 = 0
            var got: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == 0 && running != 0
        }
    }
}
