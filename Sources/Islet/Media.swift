import AppKit
import IOBluetooth

// MARK: - Bluetooth / AirPods

@MainActor
final class BluetoothModel: ObservableObject, ChangeTracking {
    struct Device: Identifiable, Equatable {
        var id: String { name }
        let name: String
        var left: Int?
        var right: Int?
        var caseLevel: Int?
        var main: Int?
        var isAudio: Bool
    }

    @Published private(set) var devices: [Device] = []
    /// Magic Mouse / Keyboard / Trackpad batteries (cheap IOKit read, refreshed with the tick).
    @Published private(set) var peripherals: [PeripheralBatteries.Device] = []
    private var connected: Set<String>?
    private var lastBatteryRefresh = Date.distantPast
    private var refreshing = false

    /// Connection changes come from IOBluetooth (cheap); battery from system_profiler (slow, so throttled).
    func tick() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let now = Set(paired.filter { $0.isConnected() }.compactMap(\.name))
        if let before = connected {
            for name in now.subtracting(before) {
                AppState.shared.hud.show(icon: "airpodspro", text: "\(name) connected", seconds: 3)
                lastBatteryRefresh = .distantPast
            }
            for name in before.subtracting(now) {
                lastBatteryRefresh = .distantPast // re-read so the disconnected device drops off the list
                AppState.shared.hud.show(icon: "airpodspro", text: "\(name) disconnected", seconds: 2)
            }
        }
        connected = now
        if now.isEmpty { update(\.devices, to: []) }
        update(\.peripherals, to: PeripheralBatteries.read())
        if !now.isEmpty, Date().timeIntervalSince(lastBatteryRefresh) > 60 { refreshBattery() }
    }

    private func refreshBattery() {
        guard !refreshing else { return }
        refreshing = true
        lastBatteryRefresh = Date()
        DispatchQueue.global(qos: .utility).async {
            let found = Self.readSystemProfiler()
            Task { @MainActor in
                self.refreshing = false
                self.devices = found
            }
        }
    }

    nonisolated private static func readSystemProfiler() -> [Device] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = (json["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let list = root["device_connected"] as? [[String: Any]] else { return [] }

        func level(_ v: Any?) -> Int? { (v as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) } }
        return list.compactMap { entry in
            guard let (name, value) = entry.first, let info = value as? [String: Any] else { return nil }
            let d = Device(name: name, left: level(info["device_batteryLevelLeft"]), right: level(info["device_batteryLevelRight"]),
                           caseLevel: level(info["device_batteryLevelCase"]), main: level(info["device_batteryLevelMain"]),
                           isAudio: (info["device_minorType"] as? String)?.localizedCaseInsensitiveContains("head") ?? false)
            return d.left == nil && d.right == nil && d.main == nil && d.caseLevel == nil ? nil : d
        }
    }
}

// MARK: - Download alerts

@MainActor
final class DownloadsModel {
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private(set) var latest: URL?

    func setEnabled(_ on: Bool) {
        source?.cancel()
        source = nil
        guard on else { return }
        // The first access to Downloads shows a permission prompt and blocks until it's answered,
        // so open the folder off the main thread.
        let path = folder.path
        DispatchQueue.global(qos: .utility).async {
            let fd = open(path, O_EVTONLY)
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            Task { @MainActor in
                guard fd >= 0 else { return }
                guard self.source == nil, AppState.shared.settings.downloadAlerts else { close(fd); return }
                self.known = names
                let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
                src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
                src.setCancelHandler { close(fd) }
                src.resume()
                self.source = src
            }
        }
    }

    private func listing() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    private func scan() {
        let now = listing()
        let added = now.subtracting(known)
        known = now
        let partial = ["crdownload", "download", "part", "partial", "tmp", "opdownload"]
        for name in added where !name.hasPrefix(".") && !partial.contains((name as NSString).pathExtension.lowercased()) {
            latest = folder.appendingPathComponent(name)
            AppState.shared.hud.show(icon: "arrow.down.circle.fill", text: "Downloaded \(name)", seconds: 3)
        }
    }
}
