import AppKit
import Darwin
import EventKit
import IOKit.ps

// MARK: - CPU / memory / disk

@MainActor
final class SystemStatsModel: ObservableObject {
    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryUsed: Double = 0
    let memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var diskFree: Double = 0
    @Published private(set) var diskTotal: Double = 0

    private var previousTicks: (used: UInt64, total: UInt64)?

    func sample() {
        sampleCPU()
        sampleMemory()
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
            diskTotal = Double(v.volumeTotalCapacity ?? 0)
        }
    }

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let used = user + system + nice, total = used + idle
        if let prev = previousTicks, total > prev.total {
            cpu = Double(used - prev.used) / Double(total - prev.total)
            cpuHistory.append(cpu)
            if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        }
        previousTicks = (used, total)
    }

    private func sampleMemory() {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let pages = Double(vm.active_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)
        memoryUsed = pages * Double(getpagesize())
    }
}

// MARK: - Battery

@MainActor
final class BatteryModel: ObservableObject, ChangeTracking {
    @Published private(set) var hasBattery = false
    @Published private(set) var percent = 0
    @Published private(set) var charging = false
    @Published private(set) var pluggedIn = false
    private var lastPluggedIn: Bool?
    private var alertedFull = false
    private var alertedLow: Int?

    var icon: String {
        if charging { return "battery.100.bolt" }
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    func refresh() {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        guard let ps = list.first,
              let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
              let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
        else { update(\.hasBattery, to: false); return }

        update(\.hasBattery, to: true)
        update(\.percent, to: cur * 100 / max)
        update(\.charging, to: d[kIOPSIsChargingKey] as? Bool ?? false)
        update(\.pluggedIn, to: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)

        if let last = lastPluggedIn, last != pluggedIn {
            AppState.shared.hud.show(icon: pluggedIn ? "bolt.fill" : icon,
                                     text: pluggedIn ? "Charging · \(percent)%" : "On battery · \(percent)%", seconds: 3)
        }
        lastPluggedIn = pluggedIn

        if pluggedIn, percent >= 100, !alertedFull, Pref.fullChargeAlert.bool {
            alertedFull = true
            AppState.shared.hud.show(icon: "battery.100.bolt", text: "Fully charged — you can unplug", seconds: 4)
        } else if percent < 95 {
            alertedFull = false
        }
        if !pluggedIn, Pref.lowBatteryAlert.bool, let level = [10, 20].first(where: { percent <= $0 }), alertedLow != level {
            alertedLow = level
            AppState.shared.hud.show(icon: "battery.25", text: "Battery low · \(percent)%", seconds: 4)
        } else if pluggedIn {
            alertedLow = nil
        }
    }
}

// MARK: - Calendar

@MainActor
final class CalendarModel: ObservableObject {
    struct Event: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: NSColor
        var joinURL: URL? = nil
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var authorized = false
    private let store = EKEventStore()

    func requestAccess() {
        let done: EKEventStoreRequestAccessCompletionHandler = { granted, _ in
            Task { @MainActor in
                self.authorized = granted
                self.reload()
            }
        }
        if #available(macOS 14, *) {
            store.requestFullAccessToEvents(completion: done)
        } else {
            store.requestAccess(to: .event, completion: done)
        }
    }

    func reloadIfAuthorized() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14, *) {
            authorized = status == .fullAccess
        } else {
            authorized = status == .authorized
        }
        if authorized { reload() }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { AppState.shared.calendar.reload() }
        }
    }

    /// Quick Add: "Lunch with Sam tomorrow 1pm" → a one-hour event at the detected date.
    func quickAdd(_ text: String) {
        guard authorized, !text.isEmpty else { return }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let match = detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        var title = text
        if let match, let range = Range(match.range, in: text) { title = text.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespaces) }
        let event = EKEvent(eventStore: store)
        event.title = title.isEmpty ? text : title
        event.startDate = match?.date ?? Date().addingTimeInterval(3600)
        event.endDate = event.startDate.addingTimeInterval(match?.duration ?? 3600 > 0 ? (match?.duration ?? 3600) : 3600)
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent)
            AppState.shared.hud.show(icon: "calendar.badge.plus", text: "Added \(event.title ?? "")")
            reload()
        } catch {
            AppState.shared.hud.show(icon: "exclamationmark.triangle", text: "Couldn't add the event")
        }
    }

    func reload() {
        guard authorized else { return }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { $0.endDate > Date() }
            .sorted { $0.startDate < $1.startDate }
            .map { Event(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Untitled",
                         start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                         color: $0.calendar?.color ?? .systemBlue,
                         joinURL: MeetingLinks.find(in: [$0.url?.absoluteString, $0.location, $0.notes])) }
    }
}
