import AppKit
import CoreLocation
import SwiftUI

// MARK: - Weather (Open-Meteo, free and keyless)

@MainActor
final class WeatherModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Hour: Identifiable { var id: Date { time }; let time: Date; let temp: Double; let code: Int }
    struct Current { let temp: Double; let code: Int; let high: Double; let low: Double; let place: String; let hours: [Hour]; let timeZone: TimeZone }

    @Published private(set) var current: Current?
    @Published private(set) var status = "Loading weather…"
    private let location = CLLocationManager()
    private var lastFetch = Date.distantPast
    private var generation = 0
    private var pending: DispatchWorkItem?

    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastFetch) > 15 * 60 else { return }
        lastFetch = Date()
        generation += 1
        let city = Pref.weatherCity.string.trimmingCharacters(in: .whitespaces)
        if !city.isEmpty {
            geocode(city)
        } else {
            location.delegate = self
            location.desiredAccuracy = kCLLocationAccuracyKilometer
            if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
            location.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            let place = (try? await CLGeocoder().reverseGeocodeLocation(loc))?.first?.locality ?? "Here"
            self.fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, place: place)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.status = "Set a city in Settings → Widgets, or allow Location" }
    }

    /// Called while the city is being typed: wait for a pause, then fetch once.
    func refreshSoon() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh(force: true) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func geocode(_ city: String) {
        let gen = generation
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1")]
        URLSession.shared.dataTask(with: c.url!) { data, _, _ in
            let r = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["results"] as? [[String: Any]])?.first
            Task { @MainActor in
                guard gen == self.generation else { return }
                guard let r, let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else {
                    self.status = "Couldn't find \(city)"
                    return
                }
                self.fetch(lat: lat, lon: lon, place: r["name"] as? String ?? city)
            }
        }.resume()
    }

    private func fetch(lat: Double, lon: Double, place: String) {
        let gen = generation
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(lat)), .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "hourly", value: "temperature_2m,weather_code"),
            .init(name: "forecast_days", value: "2"), .init(name: "timezone", value: "auto"),
            .init(name: "temperature_unit", value: Pref.weatherFahrenheit.bool ? "fahrenheit" : "celsius"),
        ]
        URLSession.shared.dataTask(with: c.url!) { data, _, _ in
            guard let json = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                  let cur = json["current"] as? [String: Any], let daily = json["daily"] as? [String: Any],
                  let hourly = json["hourly"] as? [String: Any] else {
                Task { @MainActor in
                    self.status = "Weather unavailable"
                    self.lastFetch = .distantPast // retry next minute
                }
                return
            }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd'T'HH:mm"
            if let tz = json["timezone"] as? String { f.timeZone = TimeZone(identifier: tz) }
            let times = (hourly["time"] as? [String] ?? []).compactMap(f.date)
            let temps = hourly["temperature_2m"] as? [Double] ?? []
            let codes = hourly["weather_code"] as? [Int] ?? []
            let now = Date().addingTimeInterval(-3600)
            let hours = zip(times, zip(temps, codes)).filter { $0.0 > now }.prefix(8).map { Hour(time: $0.0, temp: $0.1.0, code: $0.1.1) }
            let zone = (json["timezone"] as? String).flatMap(TimeZone.init(identifier:)) ?? .current
            let current = Current(temp: cur["temperature_2m"] as? Double ?? 0, code: cur["weather_code"] as? Int ?? 0,
                                  high: (daily["temperature_2m_max"] as? [Double])?.first ?? 0,
                                  low: (daily["temperature_2m_min"] as? [Double])?.first ?? 0,
                                  place: place, hours: Array(hours), timeZone: zone)
            Task { @MainActor in
                guard gen == self.generation else { return }
                self.current = current
                self.status = ""
            }
        }.resume()
    }

    /// WMO weather codes → SF Symbols.
    static func symbol(_ code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

// MARK: - Stocks (Yahoo Finance chart endpoint)

@MainActor
final class StocksModel: ObservableObject {
    struct Quote: Identifiable { var id: String { symbol }; let symbol: String; let price: Double; let change: Double; let points: [Double] }
    @Published private(set) var quotes: [Quote] = []
    private var lastFetch = Date.distantPast
    private var generation = 0
    private var pending: DispatchWorkItem?

    func refreshSoon() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh(force: true) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    var symbols: [String] {
        Pref.stocks.string.uppercased().split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }

    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastFetch) > 5 * 60 else { return }
        lastFetch = Date()
        generation += 1
        let gen = generation
        let symbols = self.symbols
        DispatchQueue.global(qos: .utility).async {
            let quotes = symbols.compactMap(Self.fetch)
            Task { @MainActor in
                guard gen == self.generation else { return } // symbols changed while fetching
                self.quotes = quotes
                StockAlerts.check(quotes)
            }
        }
    }

    nonisolated private static func fetch(_ symbol: String) -> Quote? {
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?range=1d&interval=15m") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in body = data; sem.signal() }.resume()
        sem.wait()
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let result = ((json["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any], let price = meta["regularMarketPrice"] as? Double else { return nil }
        let previous = meta["chartPreviousClose"] as? Double ?? meta["previousClose"] as? Double ?? price
        let closes = (((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first?["close"] as? [Double?] ?? []).compactMap { $0 }
        return Quote(symbol: symbol, price: price, change: previous > 0 ? (price - previous) / previous * 100 : 0, points: closes)
    }
}

// MARK: - Widgets tab

struct WidgetsTab: View {
    @AppStorage(Pref.worldClocks.rawValue) private var zones = ""

    var body: some View {
        HStack(spacing: Layout.gap) {
            WeatherCard()
            if !zones.isEmpty { WorldClockCard().frame(width: 170) }
            StocksCard().frame(width: 230)
        }
    }
}

struct WeatherCard: View {
    @ObservedObject private var weather = AppState.shared.weather

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let w = weather.current {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.place).font(.system(size: 12, weight: .semibold))
                        Text("\(Int(w.temp.rounded()))°").font(.system(size: 34, weight: .light, design: .rounded))
                        Text("H \(Int(w.high.rounded()))°  L \(Int(w.low.rounded()))°").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: WeatherModel.symbol(w.code)).symbolRenderingMode(.multicolor).font(.system(size: 34))
                }
                HStack(spacing: 0) {
                    ForEach(w.hours) { h in
                        VStack(spacing: 3) {
                            Text(h.time.formatted(Date.FormatStyle(timeZone: w.timeZone).hour())).font(.system(size: 9)).foregroundStyle(.secondary)
                            Image(systemName: WeatherModel.symbol(h.code)).symbolRenderingMode(.multicolor).font(.system(size: 12))
                            Text("\(Int(h.temp.rounded()))°").font(.system(size: 10))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } else {
                Text(weather.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(Layout.card).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground)
        .onAppear { weather.refresh() }
    }
}

struct StocksCard: View {
    @ObservedObject private var stocks = AppState.shared.stocks

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stocks").font(.system(size: 12, weight: .semibold))
            if stocks.quotes.isEmpty {
                Text("Add symbols in Settings → Widgets").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(stocks.quotes) { q in
                HStack {
                    Text(q.symbol).font(.system(size: 12, weight: .semibold)).frame(width: 52, alignment: .leading)
                    Sparkline(values: Self.normalized(q.points)).stroke(q.change >= 0 ? Color.green : Color.red, lineWidth: 1.2)
                        .frame(height: 16)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(String(format: "%.2f", q.price)).font(.system(size: 11)).monospacedDigit()
                        Text(String(format: "%+.2f%%", q.change)).font(.system(size: 9)).monospacedDigit()
                            .foregroundStyle(q.change >= 0 ? .green : .red)
                    }
                    .frame(width: 58, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Layout.card).frame(maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground)
        .onAppear { stocks.refresh() }
    }

    static func normalized(_ v: [Double]) -> [Double] {
        guard let lo = v.min(), let hi = v.max(), hi > lo else { return v.map { _ in 0.5 } }
        return v.map { ($0 - lo) / (hi - lo) }
    }
}

// MARK: - Menu bar extras, notch hiding, desktop widgets

@MainActor
final class MenuBarExtras: NSObject {
    private var calendarItem: NSStatusItem?
    private var calendarPopover: NSPopover?
    private var calendarTimer: Timer?
    private var hiderToggle: NSStatusItem?
    private var hiderSpacer: NSStatusItem?
    private var iconsHidden = false
    private var detachItem: NSStatusItem?
    private var detachPopover: NSPopover?
    private var notchCover: NSWindow?
    private var desktopWindow: NSWindow?

    func apply() {
        applyCalendar(Pref.menuBarCalendar.bool)
        applyIconHiding(Pref.menuBarIconHiding.bool)
        applyDetach(Pref.menuBarDetach.bool)
        applyNotchCover(Pref.hideNotch.bool)
        applyDesktopWidgets(Pref.desktopWidgets.bool)
    }

    // Calendar in the menu bar
    private func applyCalendar(_ on: Bool) {
        guard on != (calendarItem != nil) else { return }
        if !on {
            calendarItem.map(NSStatusBar.system.removeStatusItem)
            calendarItem = nil
            calendarTimer?.invalidate()
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggleCalendar)
        calendarItem = item
        updateCalendarTitle()
        calendarTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCalendarTitle() }
        }
    }

    private func updateCalendarTitle() {
        calendarItem?.button?.title = Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    @objc private func toggleCalendar() {
        if let p = calendarPopover, p.isShown { p.close(); return }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = NSHostingController(rootView: MenuCalendarView().frame(width: 280))
        calendarPopover = p
        if let button = calendarItem?.button { p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    // Hide menu bar icons: a spacer to the left of the chevron grows to push icons off-screen.
    private func applyIconHiding(_ on: Bool) {
        guard on != (hiderToggle != nil) else { return }
        if !on {
            [hiderSpacer, hiderToggle].compactMap { $0 }.forEach(NSStatusBar.system.removeStatusItem)
            hiderSpacer = nil
            hiderToggle = nil
            return
        }
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggle.button?.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Hide icons")
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleIcons)
        let spacer = NSStatusBar.system.statusItem(withLength: 8)
        spacer.button?.title = "│"
        spacer.button?.appearsDisabled = true
        hiderToggle = toggle
        hiderSpacer = spacer
        iconsHidden = false
    }

    @objc private func toggleIcons() {
        iconsHidden.toggle()
        hiderSpacer?.length = iconsHidden ? 10_000 : 8
        hiderToggle?.button?.image = NSImage(systemSymbolName: iconsHidden ? "chevron.right" : "chevron.left", accessibilityDescription: nil)
    }

    // The island in a menu bar popover instead of the notch.
    private func applyDetach(_ on: Bool) {
        NotchController.current?.setDetached(on)
        guard on != (detachItem != nil) else { return }
        if !on {
            detachItem.map(NSStatusBar.system.removeStatusItem)
            detachItem = nil
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.portrait.fill", accessibilityDescription: "Islet")
        item.button?.target = self
        item.button?.action = #selector(toggleDetached)
        detachItem = item
    }

    @objc private func toggleDetached() {
        if let p = detachPopover, p.isShown { p.close(); return }
        guard let controller = NotchController.current else { return }
        let state = NotchState()
        state.expanded = true
        state.tab = controller.state.tab
        let p = NSPopover()
        p.behavior = .transient
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentViewController = NSHostingController(rootView:
            ExpandedView(state: state, controller: controller)
                .environment(NowPlayingModel.shared)
                .frame(width: state.contentSize.width, height: state.contentSize.height)
                .foregroundStyle(.white))
        detachPopover = p
        if let button = detachItem?.button { p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    // A black strip behind the menu bar so the notch disappears into it.
    private func applyNotchCover(_ on: Bool) {
        notchCover?.orderOut(nil)
        notchCover = nil
        guard on, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { return }
        let height = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 24)
        let w = NSWindow(contentRect: NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.ignoresMouseEvents = true
        w.orderFrontRegardless()
        notchCover = w
    }

    // Widgets pinned to the desktop, beneath app windows.
    private func applyDesktopWidgets(_ on: Bool) {
        guard on != (desktopWindow != nil) else { return }
        if !on {
            desktopWindow?.orderOut(nil)
            desktopWindow = nil
            return
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 330, height: 360)
        let w = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.maxY - size.height - 24,
                                             width: size.width, height: size.height),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isMovableByWindowBackground = true
        w.contentView = NSHostingView(rootView: DesktopWidgetsView().environment(NowPlayingModel.shared))
        w.setFrameAutosaveName("IsletDesktopWidgets")
        w.orderFrontRegardless()
        desktopWindow = w
    }
}

struct MenuCalendarView: View {
    @ObservedObject private var calendar = AppState.shared.calendar
    private let cal = Calendar.current

    var body: some View {
        let today = Date()
        let month = cal.dateInterval(of: .month, for: today)!
        let firstWeekday = cal.component(.weekday, from: month.start) - cal.firstWeekday
        let days = cal.range(of: .day, in: .month, for: today)!.count
        VStack(alignment: .leading, spacing: 10) {
            Text(today.formatted(.dateTime.month(.wide).year())).font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
                ForEach(0..<7, id: \.self) { i in
                    Text(cal.veryShortWeekdaySymbols[(i + cal.firstWeekday - 1) % 7]).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(0..<((firstWeekday + 7) % 7), id: \.self) { _ in Text("") }
                ForEach(1...days, id: \.self) { day in
                    let isToday = day == cal.component(.day, from: today)
                    Text("\(day)").font(.system(size: 12, weight: isToday ? .bold : .regular))
                        .frame(width: 26, height: 22)
                        .background(Circle().fill(isToday ? Color.red : .clear))
                        .foregroundStyle(isToday ? .white : .primary)
                }
            }
            Divider()
            if calendar.events.isEmpty {
                Text(calendar.authorized ? "No more events today" : "Connect your calendar in the island").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(calendar.events.prefix(5)) { e in
                HStack {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.color)).frame(width: 3, height: 26)
                    VStack(alignment: .leading) {
                        Text(e.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(e.allDay ? "All day" : e.start.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
    }
}

struct DesktopWidgetsView: View {
    @ObservedObject private var battery = AppState.shared.battery
    @ObservedObject private var stats = AppState.shared.stats
    private var player: NowPlayingModel { .shared }

    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 0) {
                    Text(ctx.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 44, weight: .thin, design: .rounded))
                    Text(ctx.date.formatted(.dateTime.weekday(.wide).month().day())).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .adaptiveGlass(.regular, in: .rect(cornerRadius: 22, style: .continuous))
            WeatherCard().frame(height: 120)
                .adaptiveGlass(.regular, in: .rect(cornerRadius: 22, style: .continuous))
            HStack(spacing: 10) {
                gauge("CPU", stats.cpu, .cyan)
                gauge("Memory", stats.memoryTotal > 0 ? stats.memoryUsed / stats.memoryTotal : 0, .purple)
                if battery.hasBattery { gauge("Battery", Double(battery.percent) / 100, .green) }
                if let track = player.track {
                    ArtworkView(image: player.artwork, cornerRadius: 10, palette: player.palette).frame(width: 52, height: 52)
                        .help(track.title)
                }
            }
            .padding(12)
            .adaptiveGlass(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(4)
    }

    private func gauge(_ label: String, _ value: Double, _ color: Color) -> some View {
        Gauge(value: min(max(value, 0), 1)) { Text(label) } currentValueLabel: { Text("\(Int(value * 100))") }
            .gaugeStyle(.accessoryCircular).tint(color).scaleEffect(0.9)
    }
}
