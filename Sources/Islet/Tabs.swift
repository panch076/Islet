import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Inner cards are Liquid Glass panes floating on the black island (frosted material before macOS 26).
var cardBackground: some View {
    Color.clear.adaptiveGlass(GlassSpec.regular.tint(.white.opacity(0.03)), in: RoundedRectangle(cornerRadius: Layout.radius, style: .continuous))
}

// MARK: - Home

/// Home shows the cards chosen (and ordered) in Settings → Island → Home.
struct HomeTab: View {
    @AppStorage(Pref.homeCards.rawValue) private var cards = "nowPlaying,calendar"

    var body: some View {
        let ids = cards.split(separator: ",").map(String.init)
        HStack(spacing: Layout.gap) {
            ForEach(ids, id: \.self) { id in
                card(id).frame(maxWidth: id == "nowPlaying" || ids.count == 1 ? .infinity : 200)
            }
        }
    }

    @ViewBuilder private func card(_ id: String) -> some View {
        switch id {
        case "nowPlaying": NowPlayingCard()
        case "calendar": CalendarCard()
        case "weather": WeatherCard()
        case "system": StatsMiniCard()
        case "timer": TimerMiniCard()
        case "note": NoteMiniCard()
        case "worldClock": WorldClockCard()
        case "stocks": StocksCard()
        case "pet": PetMiniCard()
        default: EmptyView()
        }
    }

    static let all: [(id: String, title: String)] = [
        ("nowPlaying", "Now Playing"), ("calendar", "Calendar"), ("weather", "Weather"), ("system", "System"),
        ("timer", "Pomodoro"), ("note", "Quick Note"), ("worldClock", "World Clock"), ("stocks", "Stocks"), ("pet", "Desk Pet"),
    ]
}

private struct StatsMiniCard: View {
    @ObservedObject private var stats = AppState.shared.stats
    @ObservedObject private var battery = AppState.shared.battery

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 10) {
                Gauge(value: stats.cpu) { Text("CPU") } currentValueLabel: { Text("\(Int(stats.cpu * 100))") }.gaugeStyle(.accessoryCircular).tint(.cyan)
                Gauge(value: stats.memoryTotal > 0 ? stats.memoryUsed / stats.memoryTotal : 0) { Text("RAM") } currentValueLabel: {
                    Text("\(Int(stats.memoryTotal > 0 ? stats.memoryUsed / stats.memoryTotal * 100 : 0))")
                }.gaugeStyle(.accessoryCircular).tint(.purple)
                if battery.hasBattery {
                    Gauge(value: Double(battery.percent) / 100) { Text("Bat") } currentValueLabel: { Text("\(battery.percent)") }.gaugeStyle(.accessoryCircular).tint(.green)
                }
            }
            .scaleEffect(0.85, anchor: .leading)
            Spacer(minLength: 0)
        }
        .padding(Layout.card).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground)
    }
}

private struct TimerMiniCard: View {
    @ObservedObject private var pomodoro = AppState.shared.pomodoro

    var body: some View {
        VStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(pomodoro.display).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Text(pomodoro.phase.rawValue).font(.caption).foregroundStyle(.secondary)
            Button(pomodoro.running ? "Pause" : "Start", action: pomodoro.toggle).buttonStyle(BouncyButtonStyle())
                .padding(.horizontal, 14).padding(.vertical, 5).adaptiveGlass(.clear.interactive(), in: .capsule)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground)
    }
}

private struct NoteMiniCard: View {
    @ObservedObject private var notes = AppState.shared.notes

    var body: some View {
        TextEditor(text: $notes.text).font(.system(size: 12)).scrollContentBackground(.hidden)
            .padding(8).background(cardBackground)
    }
}

struct WorldClockCard: View {
    @AppStorage(Pref.worldClocks.rawValue) private var zones = ""

    var body: some View {
        let ids = zones.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { TimeZone(identifier: $0) != nil }
        VStack(alignment: .leading, spacing: 6) {
            Text("World Clock").font(.system(size: 12, weight: .semibold))
            if ids.isEmpty { Text("Add time zones in Settings → Widgets").font(.caption).foregroundStyle(.secondary) }
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ids, id: \.self) { id in
                        let tz = TimeZone(identifier: id)!
                        HStack {
                            Text(id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id).font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Text(ctx.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: tz))).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Layout.card).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground)
    }
}

struct CalendarCard: View {
    @ObservedObject private var calendar = AppState.shared.calendar
    @State private var adding = false
    @State private var newEvent = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Date(), format: .dateTime.weekday(.wide).month().day())
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if calendar.authorized {
                    Button { withAnimation(Motion.standard) { adding.toggle() } } label: { Image(systemName: adding ? "xmark" : "plus") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Quick add event")
                }
            }
            if adding {
                TextField("Lunch with Sam tomorrow 1pm", text: $newEvent)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    .onSubmit { calendar.quickAdd(newEvent); newEvent = ""; adding = false }
            }
            if !calendar.authorized {
                Spacer()
                Button("Connect Calendar") { calendar.requestAccess() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Spacer()
            } else if calendar.events.isEmpty {
                Spacer()
                Text("No more events today").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(calendar.events) { e in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.color)).frame(width: 3)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(e.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        if let url = e.joinURL {
                                            Button("Join") { NSWorkspace.shared.open(url) }
                                                .font(.system(size: 10, weight: .semibold)).buttonStyle(.plain)
                                                .padding(.horizontal, 6).padding(.vertical, 1)
                                                .background(Capsule().fill(Color.green.opacity(0.3)))
                                        }
                                    }
                                    Text(e.allDay ? "All day" : "\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(cardBackground)
    }
}

// MARK: - Clipboard

struct ClipboardTab: View {
    @ObservedObject private var clipboard = AppState.shared.clipboard
    @State private var search = ""

    private var items: [ClipboardModel.Item] {
        search.isEmpty ? clipboard.items : clipboard.items.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard", text: $search).textFieldStyle(.plain)
                Button("Clear", action: clipboard.clear).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(cardBackground)

            if items.isEmpty {
                Spacer()
                Text(clipboard.items.isEmpty ? "Copy something and it will show up here" : "No matches")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in
                            ClipRow(item: item)
                        }
                    }
                    .padding(.trailing, 10) // keep timestamps clear of the scroll bar
                }
            }
        }
    }
}

private struct ClipRow: View {
    let item: ClipboardModel.Item
    @State private var hovering = false

    var body: some View {
        HStack {
            if let image = AppState.shared.clipboard.thumbnail(item) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 28).clipShape(RoundedRectangle(cornerRadius: 4))
                Text(item.text.isEmpty ? "Image" : item.text)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ⏎ "))
                    .font(.system(size: 12)).lineLimit(1)
            }
            Spacer()
            Text(item.date, style: .relative).font(.system(size: 10)).foregroundStyle(.secondary)
            if hovering {
                Button { AppState.shared.clipboard.remove(item) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hovering ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { AppState.shared.clipboard.copy(item) }
        .contextMenu {
            Button("Copy") { AppState.shared.clipboard.copy(item) }
            let actions = SmartActions.actions(for: item.text)
            if !actions.isEmpty { Divider() }
            ForEach(actions) { a in Button { a.run() } label: { Label(a.title, systemImage: a.icon) } }
            Divider()
            Button("Delete") { AppState.shared.clipboard.remove(item) }
        }
    }
}

// MARK: - Shelf

struct ShelfTab: View {
    @ObservedObject private var shelf = AppState.shared.shelf

    var body: some View {
        if shelf.files.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 28))
                Text("Drag files onto the island to keep them here").font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
        } else {
            VStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(shelf.files, id: \.self) { ShelfItem(url: $0) }
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    Text("\(shelf.files.count) item\(shelf.files.count == 1 ? "" : "s") · drag out to use")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { shelf.airDrop(shelf.files) } label: { Label("AirDrop", systemImage: "airplayaudio") }
                    Button { ShelfActions.zip(shelf.files) } label: { Label("Zip All", systemImage: "doc.zipper") }
                    Button("Clear", action: shelf.clear)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
            }
        }
    }
}

private struct ShelfItem: View {
    let url: URL

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 56, height: 56)
            Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(width: 84)
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("AirDrop") { AppState.shared.shelf.airDrop([url]) }
            Divider()
            Divider()
            if url.pathExtension.lowercased() == "zip" {
                Button("Unzip") { ShelfActions.unzip(url) }
            } else {
                Button("Zip") { ShelfActions.zip([url]) }
            }
            if FileTools.isImage(url) {
                Menu("Compress To") {
                    ForEach([200, 500, 1000, 2000, 5000], id: \.self) { kb in
                        Button(kb >= 1000 ? "\(kb / 1000) MB" : "\(kb) KB") { ShelfActions.compress(url, kb * 1024) }
                    }
                }
                Menu("Convert Image To") {
                    Button("PNG") { ShelfActions.convert(url, .png) }
                    Button("JPEG") { ShelfActions.convert(url, .jpeg) }
                    Button("HEIC") { ShelfActions.convert(url, .heic) }
                    Button("TIFF") { ShelfActions.convert(url, .tiff) }
                }
            }
            Divider()
            Button("Remove from Shelf") { AppState.shared.shelf.remove(url) }
        }
    }
}

// MARK: - Notes

struct NotesTab: View {
    enum Section: String, CaseIterable { case notes = "Notes", snippets = "Snippets", reminders = "Reminders" }
    @State private var section: Section = .notes

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            switch section {
            case .notes: QuickNotes()
            case .snippets: SnippetsView()
            case .reminders: RemindersView()
            }
        }
    }
}

private struct QuickNotes: View {
    @ObservedObject private var notes = AppState.shared.notes

    var body: some View {
        TextEditor(text: $notes.text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(cardBackground)
    }
}

// MARK: - Pomodoro

struct TimerTab: View {
    enum Mode: String, CaseIterable { case pomodoro = "Pomodoro", timer = "Timer", stopwatch = "Stopwatch", stats = "Stats" }
    @State private var mode: Mode = .pomodoro

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            Group {
                switch mode {
                case .pomodoro: PomodoroView()
                case .stopwatch: StopwatchView()
                case .stats: FocusStatsView()
                case .timer: CountdownView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.blurReplace)
        }
        .animation(Motion.standard, value: mode)
    }
}

private struct PomodoroView: View {
    @ObservedObject private var pomodoro = AppState.shared.pomodoro
    @AppStorage(Pref.mascot.rawValue) private var mascot = "🐢"
    @AppStorage(Pref.pomoLongEvery.rawValue) private var longEvery = 4

    private var color: Color { pomodoro.phase == .focus ? .orange : .green }

    var body: some View {
        HStack(spacing: 24) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !pomodoro.running)) { ctx in
                let progress = pomodoro.progress(at: ctx.date)
                ZStack {
                    Circle().stroke(Color.white.opacity(0.1), lineWidth: 9)
                    Circle().trim(from: 0, to: progress)
                        .stroke(AngularGradient(colors: [color.opacity(0.6), color], center: .center),
                                style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    // The mascot rides the ring.
                    Text(mascot).font(.system(size: 16))
                        .offset(y: -66)
                        .rotationEffect(.degrees(360 * progress))
                    VStack(spacing: 0) {
                        Text(pomodoro.display)
                            .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .animation(Motion.standard, value: pomodoro.remaining)
                        Text(pomodoro.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 132, height: 132)
                .scaleEffect(pomodoro.running ? 1 : 0.98)
                .animation(Motion.standard, value: pomodoro.running)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    BouncyButton(action: pomodoro.toggle) {
                        Label(pomodoro.running ? "Pause" : "Start", systemImage: pomodoro.running ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .adaptiveGlass(GlassSpec.regular.tint(color.opacity(0.5)).interactive(), in: .capsule)
                    BouncyButton(action: pomodoro.reset) { Image(systemName: "arrow.counterclockwise").padding(7) }
                        .adaptiveGlass(.clear.interactive(), in: .circle)
                    BouncyButton(action: pomodoro.skip) { Image(systemName: "forward.end.fill").padding(7) }
                        .adaptiveGlass(.clear.interactive(), in: .circle)
                }
                HStack(spacing: 5) {
                    ForEach(0..<max(longEvery, 1), id: \.self) { i in
                        Circle()
                            .fill(i < pomodoro.sessionsInCycle % max(longEvery, 1) ? color : Color.white.opacity(0.15))
                            .frame(width: 7, height: 7)
                    }
                    Text("until long break").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Stepper("Focus \(pomodoro.focusMinutes) min", value: $pomodoro.focusMinutes, in: 1...180)
                Stepper("Break \(pomodoro.breakMinutes) min", value: $pomodoro.breakMinutes, in: 1...60)
            }
            .font(.system(size: 12))
            Spacer(minLength: 0)
        }
    }
}

private struct StopwatchView: View {
    @ObservedObject private var stopwatch = AppState.shared.stopwatch

    var body: some View {
        HStack(spacing: 20) {
            VStack(spacing: 10) {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !stopwatch.running)) { ctx in
                    Text(StopwatchModel.format(stopwatch.elapsed(at: ctx.date)))
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                HStack(spacing: 10) {
                    BouncyButton(action: stopwatch.toggle) {
                        Text(stopwatch.running ? "Stop" : "Start").frame(width: 60).padding(.vertical, 6)
                    }
                    .adaptiveGlass(GlassSpec.regular.tint((stopwatch.running ? Color.red : Color.green).opacity(0.5)).interactive(), in: .capsule)
                    BouncyButton(action: stopwatch.running ? stopwatch.lap : stopwatch.reset) {
                        Text(stopwatch.running ? "Lap" : "Reset").frame(width: 60).padding(.vertical, 6)
                    }
                    .adaptiveGlass(.clear.interactive(), in: .capsule)
                }
            }
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Array(stopwatch.laps.enumerated()), id: \.offset) { i, t in
                        HStack {
                            Text("Lap \(stopwatch.laps.count - i)").foregroundStyle(.secondary)
                            Spacer()
                            Text(StopwatchModel.format(t)).monospacedDigit()
                        }
                        .font(.system(size: 11))
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(Motion.standard, value: stopwatch.laps.count)
            }
            .frame(width: 180)
        }
    }
}

private struct FocusStatsView: View {
    @ObservedObject private var pomodoro = AppState.shared.pomodoro
    @AppStorage(Pref.pomoGoal.rawValue) private var goal = 8

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                stat("flame.fill", .orange, "\(pomodoro.streak)", "day streak")
                stat("target", .green, "\(pomodoro.todaySessions)/\(goal)", "sessions today")
                stat("clock.fill", .cyan, "\(pomodoro.todayMinutes)m", "focused today")
            }
            .frame(width: 150, alignment: .leading)
            Chart(pomodoro.lastSevenDays, id: \.day) { entry in
                BarMark(x: .value("Day", entry.day, unit: .day), y: .value("Minutes", entry.minutes))
                    .foregroundStyle(Calendar.current.isDateInToday(entry.day) ? Color.orange : Color.orange.opacity(0.5))
                    .cornerRadius(4)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
            .chartYAxis { AxisMarks(position: .leading) }
        }
        .padding(10)
        .background(cardBackground)
    }

    private func stat(_ icon: String, _ color: Color, _ value: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Stats

struct StatsTab: View {
    @ObservedObject private var stats = AppState.shared.stats
    @ObservedObject private var battery = AppState.shared.battery

    var body: some View {
        HStack(spacing: Layout.gap) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CPU").font(.caption).foregroundStyle(.secondary)
                Text("\(Int(stats.cpu * 100))%").font(.system(size: 26, weight: .semibold, design: .rounded))
                Sparkline(values: stats.cpuHistory).stroke(Color.cyan, lineWidth: 1.5)
            }
            .padding(Layout.card).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(cardBackground)

            VStack(alignment: .leading, spacing: 10) {
                meter("Memory", used: stats.memoryUsed, total: stats.memoryTotal, color: .purple)
                meter("Disk", used: stats.diskTotal - stats.diskFree, total: stats.diskTotal, color: .blue)
                if battery.hasBattery {
                    meter("Battery", used: Double(battery.percent), total: 100, color: battery.percent < 20 ? .red : .green, unit: "%")
                }
                Text("Uptime \(uptime)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(Layout.card).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(cardBackground)

            ActivityCard()
        }
    }

    private var uptime: String {
        let s = Int(ProcessInfo.processInfo.systemUptime)
        return s >= 86400 ? "\(s / 86400)d \(s % 86400 / 3600)h" : "\(s / 3600)h \(s % 3600 / 60)m"
    }

    private func meter(_ title: String, used: Double, total: Double, color: Color, unit: String? = nil) -> some View {
        let gb = 1_073_741_824.0
        let label = unit != nil ? "\(Int(used))\(unit!)" : String(format: "%.1f / %.0f GB", used / gb, total / gb)
        return VStack(alignment: .leading, spacing: 3) {
            HStack { Text(title); Spacer(); Text(label).monospacedDigit().foregroundStyle(.secondary) }
                .font(.system(size: 11))
            ProgressView(value: total > 0 ? min(used / total, 1) : 0).tint(color)
        }
    }
}

struct Sparkline: Shape {
    var values: [Double]

    func path(in r: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let step = r.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: CGFloat(i) * step, y: r.maxY - CGFloat(v) * r.height)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}

// MARK: - Countdown timer view

private struct CountdownView: View {
    @ObservedObject private var timer = AppState.shared.countdown

    var body: some View {
        HStack(spacing: 20) {
            if timer.running {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.1), lineWidth: 8)
                        Circle().trim(from: 0, to: timer.total > 0 ? 1 - timer.remaining(at: ctx.date) / timer.total : 0)
                            .stroke(Color.cyan, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: timer.remaining(at: ctx.date))
                        Text(timer.display).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    .frame(width: 128, height: 128)
                }
            } else {
                HStack(spacing: 4) {
                    wheel($timer.hours, 0..<24, "h")
                    wheel($timer.minutes, 0..<60, "m")
                    wheel($timer.seconds, 0..<60, "s")
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(timer.running ? "Cancel" : "Start") { timer.running ? timer.cancel() : timer.start() }
                        .buttonStyle(BouncyButtonStyle()).padding(.horizontal, 14).padding(.vertical, 5)
                        .adaptiveGlass(GlassSpec.regular.tint((timer.running ? Color.red : Color.cyan).opacity(0.5)).interactive(), in: .capsule)
                }
                HStack(spacing: 6) {
                    ForEach([1, 5, 10, 15, 30, 60], id: \.self) { m in
                        Button("\(m)m") { timer.start(TimeInterval(m * 60)) }.buttonStyle(BouncyButtonStyle())
                            .font(.system(size: 11)).padding(.horizontal, 7).padding(.vertical, 3).adaptiveGlass(.clear.interactive(), in: .capsule)
                    }
                }
                Toggle("Repeat", isOn: $timer.repeats).toggleStyle(.switch).controlSize(.mini)
            }
            .font(.system(size: 12))
            Spacer(minLength: 0)
        }
    }

    private func wheel(_ value: Binding<Int>, _ range: Range<Int>, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Button { value.wrappedValue = min(range.upperBound - 1, value.wrappedValue + 1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain)
            Text(String(format: "%02d", value.wrappedValue)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 44)
    }
}

// MARK: - Activity: top processes, screen time, data usage

private struct ActivityCard: View {
    @ObservedObject private var screenTime = AppState.shared.screenTime
    @ObservedObject private var data = AppState.shared.dataUsage
    @State private var processes: [ProcessTools.Proc] = []
    @State private var showWeek = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Top processes").font(.caption).foregroundStyle(.secondary)
            ForEach(processes.prefix(3)) { p in
                HStack { Text(p.name).lineLimit(1); Spacer(); Text(String(format: "%.0f%%", p.cpu)).monospacedDigit() }.font(.system(size: 11))
            }
            HStack {
                Text(showWeek ? "Screen time · week" : "Screen time · today").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showWeek.toggle() } label: { Image(systemName: "arrow.left.arrow.right") }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            ForEach((showWeek ? screenTime.week : screenTime.today).sorted { $0.value > $1.value }.prefix(3), id: \.key) { app, secs in
                HStack { Text(app).lineLimit(1); Spacer(); Text(ScreenTimeModel.format(secs)).monospacedDigit() }.font(.system(size: 11))
            }
            Text("↓ \(ByteCountFormatter.string(fromByteCount: Int64(data.todayIn), countStyle: .file))  ↑ \(ByteCountFormatter.string(fromByteCount: Int64(data.todayOut), countStyle: .file)) today")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(Layout.card).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground)
        // A task survives the card being re-created every second; a Timer.publish stored on the struct didn't.
        .task {
            while !Task.isCancelled {
                load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func load() {
        DispatchQueue.global(qos: .utility).async {
            let top = ProcessTools.top(3)
            Task { @MainActor in processes = top }
        }
    }
}

private struct PetMiniCard: View {
    @ObservedObject private var pet = AppState.shared.pet
    @AppStorage(Pref.petSpecies.rawValue) private var species = "🐱"
    @AppStorage(Pref.petHue.rawValue) private var hue = 0.0

    var body: some View {
        VStack(spacing: 6) {
            Text(species).font(.system(size: 36)).hueRotation(.degrees(hue))
            Text(pet.name).font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                Button { pet.feed() } label: { Image(systemName: "fork.knife").frame(width: 26, height: 26) }
                Button { pet.petted() } label: { Image(systemName: "hand.raised.fill").frame(width: 26, height: 26) }
                Button { pet.play() } label: { Image(systemName: "figure.play").frame(width: 26, height: 26) }
            }
            .buttonStyle(BouncyButtonStyle())
            .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground)
    }
}
