import Lottie
import SwiftUI
import Translation
import UniformTypeIdentifiers

struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = min(topRadius, r.height / 2, r.width / 2)
        let b = min(bottomRadius, r.height / 2, r.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + t), radius: t)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - b))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - b, y: r.maxY), radius: b)
        p.addLine(to: CGPoint(x: r.minX + b, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - b), radius: b)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + t))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + t, y: r.minY), radius: t)
        p.closeSubpath()
        return p
    }
}

/// Text sent from the command palette to the system translation sheet.
@MainActor
final class TranslateRequest: ObservableObject {
    static let shared = TranslateRequest()
    @Published var text = ""
    @Published var show = false
}

struct IslandRootView: View {
    @ObservedObject var state: NotchState
    let controller: NotchController
    @ObservedObject private var shelf = AppState.shared.shelf
    @ObservedObject private var settings = AppState.shared.settings
    @State private var dropTargeted = false
    // Read through @AppStorage so changing them in Settings re-renders the island immediately.
    @AppStorage(Pref.doubleClickOpen.rawValue) private var doubleClickOpen = false
    @AppStorage(Pref.monochrome.rawValue) private var monochrome = false
    @AppStorage(Pref.fontDesign.rawValue) private var fontDesign = "rounded"
    /// A brief overshoot when the island opens or closes, so it feels like liquid settling.
    @State private var wobble: CGFloat = 1

    /// A collapsed island around a real notch stays black so it blends with the camera housing.
    private var useGlass: Bool {
        settings.islandStyle == .glass && (state.expanded || state.peeking || !state.hasNotch)
    }

    private var shape: IslandShape {
        let open = state.expanded || state.peeking
        if state.hasNotch {
            return IslandShape(topRadius: 0, bottomRadius: open ? 26 : 10)
        }
        let r = open ? 26 : state.collapsedSize.height / 2
        return IslandShape(topRadius: r, bottomRadius: r)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                IslandBackground(shape: shape, glass: useGlass, expanded: state.expanded || state.peeking)
                if state.expanded {
                    ExpandedView(state: state, controller: controller)
                        .frame(width: state.expandedSize.width, height: state.expandedSize.height, alignment: .top)
                        .clipped()
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.97, anchor: .top).combined(with: .opacity).animation(Motion.open.delay(0.04)),
                            removal: .opacity.animation(.easeOut(duration: 0.12))))
                } else if state.peeking {
                    PeekView(state: state, controller: controller)
                        .transition(.blurReplace.combined(with: ScaleTransition(0.92, anchor: .top)))
                } else {
                    CollapsedView(state: state)
                        .contentShape(Rectangle())
                        .onTapGesture(count: doubleClickOpen ? 2 : 1) { controller.expand(sticky: true, resetTab: true) }
                        .transition(.blurReplace)
                }
            }
            .frame(width: state.size.width, height: state.size.height)
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(dropTargeted ? 0.5 : 0), lineWidth: 2))
            .shadow(color: .black.opacity(state.expanded ? 0.45 : 0), radius: 18, y: 8)
            .scaleEffect(x: wobble, y: 2 - wobble, anchor: .top)
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in AppState.shared.shelf.add(url) }
                    }
                }
                state.tab = .shelf
                return true
            }
            .onChange(of: state.expanded) { _, open in
                guard Pref.openAnimation.string == "bouncy" else { return }
                wobble = open ? 1.012 : 0.992
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { wobble = 1 }
            }
            .padding(.top, state.topInset)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .fontDesign(Self.design(fontDesign))
        .saturation(monochrome ? 0 : 1)
        .opacity(state.invisible || state.hidden ? 0 : 1)
    }

    static func design(_ name: String) -> Font.Design {
        switch name {
        case "serif": return .serif
        case "monospaced": return .monospaced
        case "default": return .default
        default: return .rounded
        }
    }
}

/// Solid black, or Liquid Glass on macOS 26 (falls back to a dark material on older systems).
/// The glass is interactive, so it ripples and stretches under the pointer.
struct IslandBackground: View {
    let shape: IslandShape
    let glass: Bool
    var expanded = false
    @AppStorage(Pref.translucency.rawValue) private var translucency = 0.35
    @AppStorage(Pref.customColors.rawValue) private var customColors = false
    @AppStorage(Pref.pillColor.rawValue) private var pillColor = "#000000"
    @AppStorage(Pref.panelColor.rawValue) private var panelColor = "#000000"
    @AppStorage(Pref.panelGradient.rawValue) private var gradient = false
    @AppStorage(Pref.panelColor2.rawValue) private var panelColor2 = "#1E1B4B"

    var body: some View {
        if !glass {
            if customColors {
                if expanded && gradient {
                    shape.fill(LinearGradient(colors: [Color(hex: panelColor), Color(hex: panelColor2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    shape.fill(Color(hex: expanded ? panelColor : pillColor))
                }
            } else {
                shape.fill(Color.black)
            }
        } else if #available(macOS 26, *) {
            let tint = customColors ? Color(hex: expanded ? panelColor : pillColor) : .black
            Color.clear.glassEffect(.regular.tint(tint.opacity(translucency)).interactive(), in: shape)
        } else {
            shape.fill(.ultraThinMaterial).overlay(shape.fill(Color.black.opacity(translucency)))
        }
    }
}

// MARK: - Collapsed (live activities)

struct CollapsedView: View {
    @ObservedObject var state: NotchState
    private var player: NowPlayingModel { .shared }
    @ObservedObject private var pomodoro = AppState.shared.pomodoro
    @ObservedObject private var hud = AppState.shared.hud
    @ObservedObject private var audio = AppState.shared.audio
    @ObservedObject private var calls = AppState.shared.calls
    @ObservedObject private var agents = AppState.shared.agents
    @ObservedObject private var shell = AppState.shared.shell
    @ObservedObject private var weather = AppState.shared.weather
    @AppStorage(Pref.mascot.rawValue) private var mascot = "🐢"
    @AppStorage(Pref.idleAnimation.rawValue) private var idle = "clock"

    private var activity: AppState.Activity { state.activity }

    var body: some View {
        HStack(spacing: 8) {
            leading
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            Spacer(minLength: state.hasNotch ? state.notchSize.width : 0)
            trailing
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            if let second = state.secondary {
                SecondaryBadge(activity: second)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: state.collapsedSize.height)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .overlay(alignment: .topTrailing) { privacyDots.padding(.top, 4).padding(.trailing, 6) }
        .overlay(alignment: .bottom) { if activity == .timer { mascotTrack } }
        .animation(Motion.standard, value: activity)
        .animation(Motion.standard, value: hud.current)
    }

    /// Like the system indicator: green for camera, orange for microphone.
    @ViewBuilder private var privacyDots: some View {
        if activity != .privacy {
            HStack(spacing: 3) {
                if audio.cameraInUse { Circle().fill(Color.green).frame(width: 5, height: 5) }
                if audio.micInUse { Circle().fill(Color.orange).frame(width: 5, height: 5) }
            }
        }
    }

    /// The timer mascot walks along the bottom edge as the session progresses.
    private var mascotTrack: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            GeometryReader { geo in
                let p = pomodoro.progress(at: ctx.date)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.orange.opacity(0.35)).frame(width: geo.size.width * p, height: 2)
                    Text(mascot).font(.system(size: 9)).offset(x: max(0, geo.size.width * p - 6), y: -5)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .padding(.horizontal, 14)
            .frame(height: 10)
            .animation(.linear(duration: 1), value: p(ctx.date))
        }
    }

    private func p(_ d: Date) -> Double { pomodoro.progress(at: d) }

    @ViewBuilder private var leading: some View {
        switch activity {
        case .call:
            HStack(spacing: 4) {
                Image(systemName: "phone.fill").foregroundStyle(.green).symbolEffect(.pulse)
                if !state.hasNotch { Text(calls.app ?? "").lineLimit(1) }
            }
        case .agent:
            HStack(spacing: 5) {
                if agents.active?.state == .waiting {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange).symbolEffect(.pulse)
                } else {
                    ProgressView().controlSize(.mini).tint(.white)
                }
                if !state.hasNotch { Text(agents.active?.name ?? "").lineLimit(1) }
            }
        case .shell:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(.green)
                if !state.hasNotch {
                    Text(shell.visible?.command ?? "").font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1)
                }
            }
        case .privacy:
            HStack(spacing: 4) {
                if audio.cameraInUse { Image(systemName: "video.fill").foregroundStyle(.green) }
                if audio.micInUse { Image(systemName: audio.micMuted ? "mic.slash.fill" : "mic.fill").foregroundStyle(.orange) }
            }
        case .hud:
            if let app = hud.current?.app, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: hud.current?.icon ?? "info.circle")
                    .contentTransition(.symbolEffect(.replace))
            }
        case .countdown:
            Image(systemName: "timer").foregroundStyle(.cyan)
        case .timer:
            HStack(spacing: 4) {
                Text(mascot)
                if !state.hasNotch { Text(pomodoro.phase.rawValue).foregroundStyle(.orange) }
            }
        case .music:
            ArtworkView(image: player.artwork, cornerRadius: Pref.squareArt.bool ? 2 : 5, palette: player.palette).frame(width: 20, height: 20)
                .id(player.track?.id)
                .transition(.scale.combined(with: .opacity))
        case .none:
            if !state.hasNotch { IdleView(style: idle) }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch activity {
        case .call:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 5) {
                    if audio.micMuted { Image(systemName: "mic.slash.fill").foregroundStyle(.red) }
                    Text(calls.started.map { CallModel.duration(since: $0) } ?? "").monospacedDigit().foregroundStyle(.green)
                }
            }
        case .agent:
            if let agent = agents.active {
                if agent.state == .waiting {
                    Text(state.hasNotch ? "Waiting" : "needs you").foregroundStyle(.orange)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(CallModel.duration(since: agent.since)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        case .shell:
            if let c = shell.visible {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(CallModel.duration(since: c.started)).monospacedDigit().foregroundStyle(.green)
                }
            }
        case .privacy:
            Text(audio.cameraInUse ? "Camera on" : audio.micAppNames.first.map { "\($0) · mic" } ?? "Mic in use")
                .lineLimit(1).foregroundStyle(.secondary)
        case .hud:
            if let progress = hud.current?.progress {
                HStack(spacing: 6) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(Color.white).frame(width: 70 * progress)
                    }
                    .frame(width: 70, height: 5)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: progress)
                    Text(hud.current?.text ?? "").monospacedDigit().contentTransition(.numericText()).frame(width: 34, alignment: .trailing)
                }
            } else {
                Text(hud.current?.text ?? "").lineLimit(1).contentTransition(.opacity)
            }
        case .countdown:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(AppState.shared.countdown.display).monospacedDigit().foregroundStyle(.cyan)
            }
        case .timer:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(pomodoro.display).monospacedDigit().foregroundStyle(.orange)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring(response: 0.3), value: pomodoro.remaining)
            }
        case .music:
            if !state.hasNotch {
                Text(player.track?.title ?? "").lineLimit(1).foregroundStyle(.secondary)
            }
            EqualizerBars(animating: player.isPlaying)
        case .none:
            if state.hasNotch, idle != "none" { IdleView(style: idle).frame(width: 28) }
        }
    }
}

/// A compact second activity shown at the far edge (Multiple Live Activities).
private struct SecondaryBadge: View {
    let activity: AppState.Activity
    @ObservedObject private var pomodoro = AppState.shared.pomodoro

    var body: some View {
        Group {
            switch activity {
            case .timer:
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(pomodoro.display).monospacedDigit().foregroundStyle(.orange).font(.system(size: 10, weight: .semibold, design: .rounded))
                }
            case .music: EqualizerBars(animating: NowPlayingModel.shared.isPlaying).scaleEffect(0.8)
            case .call: Image(systemName: "phone.fill").foregroundStyle(.green)
            case .agent: ProgressView().controlSize(.mini).tint(.white)
            case .shell: Image(systemName: "terminal.fill").foregroundStyle(.green)
            default: EmptyView()
            }
        }
        .frame(width: 40)
    }
}

/// What the pill shows when nothing is happening (Settings → Island → Idle).
struct IdleView: View {
    let style: String
    @ObservedObject private var weather = AppState.shared.weather
    @AppStorage(Pref.lottiePath.rawValue) private var lottiePath = ""
    @AppStorage(Pref.lottieSpeed.rawValue) private var speed = 1.0
    @AppStorage(Pref.lottieScale.rawValue) private var scale = 1.0
    @AppStorage(Pref.lottieOffset.rawValue) private var offset = 0.0
    @State private var breathe = false

    var body: some View {
        switch style {
        case "clock":
            Clock().frame(maxWidth: .infinity)
        case "weather":
            if let w = weather.current {
                HStack(spacing: 4) {
                    Image(systemName: WeatherModel.symbol(w.code)).symbolRenderingMode(.multicolor)
                    Text("\(Int(w.temp.rounded()))°")
                }
                .frame(maxWidth: .infinity)
            } else {
                Clock().frame(maxWidth: .infinity)
            }
        case "breathing":
            Circle().fill(Color.white.opacity(0.8)).frame(width: 6, height: 6)
                .scaleEffect(breathe ? 1.4 : 0.7).opacity(breathe ? 1 : 0.4)
                .frame(maxWidth: .infinity)
                .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever()) { breathe = true } }
        case "lottie" where !lottiePath.isEmpty:
            LottieIdle(path: lottiePath, speed: speed)
                .id(lottiePath) // a new file needs a new view
                .scaleEffect(scale)
                .offset(y: offset)
                .frame(maxWidth: .infinity, maxHeight: 26)
        default:
            EmptyView()
        }
    }
}

/// The user's own Lottie JSON animation.
private struct LottieIdle: NSViewRepresentable {
    let path: String
    let speed: Double

    func makeNSView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView(filePath: path)
        view.loopMode = .loop
        view.contentMode = .scaleAspectFit
        view.animationSpeed = speed
        view.play()
        return view
    }

    func updateNSView(_ view: LottieAnimationView, context: Context) {
        view.animationSpeed = speed
    }
}

/// The pill clock: time, date or both, five date formats, optional seconds.
struct Clock: View {
    @AppStorage(Pref.clockFormat.rawValue) private var format = "time"
    @AppStorage(Pref.dateFormat.rawValue) private var dateFormat = 0
    @AppStorage(Pref.clockSeconds.rawValue) private var seconds = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(text(ctx.date)).monospacedDigit().lineLimit(1)
        }
    }

    private func text(_ d: Date) -> String {
        let time = seconds ? d.formatted(.dateTime.hour().minute().second()) : d.formatted(date: .omitted, time: .shortened)
        let date: String
        switch dateFormat {
        case 1: date = d.formatted(.dateTime.month(.abbreviated).day())
        case 2: date = d.formatted(.dateTime.day().month(.twoDigits))
        case 3: date = d.formatted(.dateTime.month(.twoDigits).day())
        case 4: date = d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        default: date = d.formatted(.dateTime.weekday(.abbreviated).day())
        }
        switch format {
        case "date": return date
        case "both": return "\(date)  \(time)"
        default: return time
        }
    }
}

/// Music bars: the real spectrum when Live Audio Spectrum is on, otherwise an animation.
struct EqualizerBars: View {
    var animating: Bool
    @ObservedObject private var spectrum = AppState.shared.spectrum

    var body: some View {
        if spectrum.running {
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<spectrum.bands.count, id: \.self) { i in
                    Capsule().fill(NowPlayingModel.shared.accent.mix(with: .green, by: 0.3))
                        .frame(width: 3, height: 3 + 11 * CGFloat(spectrum.bands[i]))
                }
            }
            .frame(height: 14)
            .animation(.spring(response: 0.15, dampingFraction: 0.6), value: spectrum.bands)
        } else {
            TimelineView(.animation(minimumInterval: 0.12, paused: !animating)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule()
                            .fill(Color.green)
                            .frame(width: 3, height: animating ? 4 + 10 * abs(sin(t * 3 + Double(i) * 1.3)) : 4)
                    }
                }
                .frame(height: 14)
                .animation(.easeInOut(duration: 0.12), value: t)
            }
        }
    }
}

struct Artwork: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Peek (mini player on a quick hover)

struct PeekView: View {
    @ObservedObject var state: NotchState
    let controller: NotchController
    private var model: NowPlayingModel { .shared }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(image: model.artwork, cornerRadius: 10, palette: model.palette)
                .frame(width: 50, height: 50)
                .shadow(color: model.accent.opacity(0.5), radius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.track?.title ?? "").font(.system(size: 13, weight: .bold)).lineLimit(1)
                Text(model.track?.artist ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                MiniLyricLine().frame(height: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CompactTransport().scaleEffect(0.85)
        }
        .padding(.horizontal, 14)
        .padding(.top, state.hasNotch ? state.notchSize.height + 4 : 12)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onTapGesture { controller.expand(sticky: true) }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @AppStorage(Pref.tabsHidden.rawValue) private var tabsHidden = ""
    @ObservedObject var state: NotchState
    let controller: NotchController
    @ObservedObject private var keepAwake = AppState.shared.keepAwake
    @ObservedObject private var battery = AppState.shared.battery
    @ObservedObject private var audio = AppState.shared.audio
    @ObservedObject private var focus = AppState.shared.focus
    @ObservedObject private var calls = AppState.shared.calls
    @ObservedObject private var agents = AppState.shared.agents
    @ObservedObject private var translate = TranslateRequest.shared
    @Namespace private var tabs

    var body: some View {
        VStack(spacing: 10) {
            header
                // Only the selection pill animates; the tab content swaps instantly. Animating the content
                // kept the old and new tabs alive and re-laid out every frame, which stalled quick switching.
                .animation(Motion.standard, value: state.tab)
            Group {
                switch state.tab {
                case .home: HomeTab()
                case .clipboard: ClipboardTab()
                case .shelf: ShelfTab()
                case .notes: NotesTab()
                case .timer: TimerTab()
                case .stats: StatsTab()
                case .lyrics: LyricsTab()
                case .sound: SoundTab()
                case .ai: AIUsageTab()
                case .terminal: TerminalTab()
                case .widgets: WidgetsTab()
                case .tools: ToolsTab()
                case .ask: AskAITab()
                case .pet: PetTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .padding(.horizontal, Layout.outer)
        .padding(.bottom, Layout.outer)
        .padding(.top, state.hasNotch ? state.notchSize.height + 4 : 12)
        .overlay {
            if state.paletteOpen {
                CommandPaletteView(state: state, controller: controller)
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let approval = agents.pendingApproval {
                ApprovalBanner(approval: approval)
                    .padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.standard, value: agents.pendingApproval?.id)
        .translationPresentation(isPresented: $translate.show, text: translate.text)
    }

    private var header: some View {
        HStack(spacing: Layout.gap) {
            // Tabs: equal-width hit targets on a 30 pt grid; scrolls sideways if the panel is narrow.
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(IslandTab.allCases.filter { !tabsHidden.split(separator: ",").contains(Substring($0.rawValue)) }) { tab in
                        Button {
                            state.tab = tab
                        } label: {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(state.tab == tab ? Color.white : Color.white.opacity(0.6))
                                .frame(width: 26, height: 26)
                                .background {
                                    if state.tab == tab {
                                        Color.clear.adaptiveGlass(GlassSpec.regular.tint(.white.opacity(0.08)), in: .circle)
                                            .matchedGeometryEffect(id: "tab", in: tabs)
                                    }
                                }
                                .contentShape(Circle())
                        }
                        .buttonStyle(BouncyButtonStyle())
                        .help(tab.title)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)

            // Status and quick actions, evenly spaced.
            HStack(spacing: 6) {
                if let app = calls.app {
                    Label(app, systemImage: "phone.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Capsule().fill(Color.green.opacity(0.25)))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }
                if let name = focus.current {
                    Image(systemName: "moon.fill").font(.system(size: 11)).foregroundStyle(.indigo).frame(width: 18).help(name)
                }
                if battery.hasBattery {
                    Label("\(battery.percent)%", systemImage: battery.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(battery.charging ? .green : .secondary)
                }
                headerButton(audio.micMuted ? "mic.slash.fill" : "mic.fill", audio.micMuted ? .red : .secondary, "Mute microphone (⌃⌥M)") {
                    AppState.shared.audio.toggleMic()
                }
                headerButton("web.camera", .secondary, "Camera mirror") {
                    UserDefaults.standard.set("Mirror", forKey: "toolsSection")
                    controller.open(tab: .tools)
                }
                headerButton("camera.viewfinder", .secondary, "Capture a selection to the clipboard") {
                    controller.collapse()
                    ScreenCapture.capture(.selectionToClipboard)
                }
                headerButton(keepAwake.enabled ? "cup.and.saucer.fill" : "cup.and.saucer", keepAwake.enabled ? .yellow : .secondary, "Keep Awake") {
                    keepAwake.toggle()
                }
                headerButton("gearshape.fill", .secondary, "Settings") {
                    controller.collapse()
                    SettingsWindowController.shared.show()
                }
            }
            .fixedSize()
        }
        .frame(height: 28)
        .animation(Motion.standard, value: calls.app)
    }

    private func headerButton(_ icon: String, _ color: Color, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).foregroundStyle(color).contentTransition(.symbolEffect(.replace))
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(BouncyButtonStyle())
        .adaptiveGlass(.clear.interactive(), in: .circle)
        .help(help)
    }
}

/// An agent asking permission, answered right from the island (Agent Approvals).
private struct ApprovalBanner: View {
    let approval: AgentModel.Approval

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange).symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(approval.agent) wants to use \(approval.tool)").font(.system(size: 12, weight: .semibold))
                if !approval.detail.isEmpty {
                    Text(approval.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            BouncyButton { AppState.shared.agents.decide(approval.id, .deny) } label: {
                Text("Deny").padding(.horizontal, 12).padding(.vertical, 5)
            }
            .adaptiveGlass(GlassSpec.regular.tint(.red.opacity(0.5)).interactive(), in: .capsule)
            BouncyButton { AppState.shared.agents.allowAlways(approval.id) } label: {
                Text("Always").padding(.horizontal, 10).padding(.vertical, 5)
            }
            .adaptiveGlass(.clear.interactive(), in: .capsule)
            .help("Always allow \(approval.tool) for \(approval.agent)")
            BouncyButton { AppState.shared.agents.decide(approval.id, .allow) } label: {
                Text("Allow").padding(.horizontal, 12).padding(.vertical, 5)
            }
            .adaptiveGlass(GlassSpec.regular.tint(.green.opacity(0.5)).interactive(), in: .capsule)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.orange.opacity(0.5)))
    }
}

// MARK: - Command palette (⌃⌥K)

struct CommandPaletteView: View {
    @ObservedObject var state: NotchState
    let controller: NotchController
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    struct Command: Identifiable {
        let id: String
        let icon: String
        let run: @MainActor () -> Void
    }

    private var commands: [Command] {
        let s = AppState.shared
        var list: [Command] = [
            Command(id: "Play / Pause", icon: "playpause.fill") { s.nowPlaying.togglePlayPause() },
            Command(id: "Next Track", icon: "forward.fill") { s.nowPlaying.next() },
            Command(id: "Previous Track", icon: "backward.fill") { s.nowPlaying.previous() },
            Command(id: s.keepAwake.enabled ? "Turn Off Keep Awake" : "Turn On Keep Awake", icon: "cup.and.saucer") { s.keepAwake.toggle() },
            Command(id: s.pomodoro.running ? "Pause Pomodoro" : "Start Pomodoro", icon: "timer") { s.pomodoro.toggle() },
            Command(id: "Reset Pomodoro", icon: "arrow.counterclockwise") { s.pomodoro.reset() },
            Command(id: "Clear Clipboard History", icon: "trash") { s.clipboard.clear() },
            Command(id: "Clear Shelf", icon: "tray") { s.shelf.clear() },
            Command(id: s.audio.micMuted ? "Unmute Microphone" : "Mute Microphone", icon: "mic.slash") { s.audio.toggleMic() },
            Command(id: "Screenshot Selection to Clipboard", icon: "camera.viewfinder") { ScreenCapture.capture(.selectionToClipboard) },
            Command(id: "Screenshot Selection to Desktop", icon: "camera.viewfinder") { ScreenCapture.capture(.selectionToDesktop) },
            Command(id: "Screenshot Window to Clipboard", icon: "macwindow") { ScreenCapture.capture(.windowToClipboard) },
            Command(id: "Screenshot Full Screen to Desktop", icon: "display") { ScreenCapture.capture(.fullScreenToDesktop) },
            Command(id: "Open Settings", icon: "gearshape") { SettingsWindowController.shared.show() },
            Command(id: "Full-Screen Lyrics", icon: "quote.bubble") { FullScreenLyrics.shared.show() },
            Command(id: "Pick a Color", icon: "eyedropper.halffull") { Eyedropper.pick() },
            Command(id: s.screenLight.on ? "Turn Off Screen Light" : "Turn On Screen Light", icon: "light.max") { s.screenLight.toggle() },
            Command(id: "Lock Keyboard for Cleaning", icon: "keyboard.badge.ellipsis") { s.keyboardTools.startCleaning() },
            Command(id: s.stopwatch.running ? "Stop Stopwatch" : "Start Stopwatch", icon: "stopwatch") { s.stopwatch.toggle() },
            Command(id: "Eject All Drives", icon: "eject") { s.drives.ejectAll() },
            Command(id: "Quit Islet", icon: "power") { NSApp.terminate(nil) },
        ]
        for app in s.launcher.all {
            list.append(Command(id: "Open \(app.name)", icon: "app") { s.launcher.launch(app) })
        }
        for name in s.shortcuts.names {
            list.append(Command(id: "Run Shortcut: \(name)", icon: "square.2.layers.3d") { s.shortcuts.run(name) })
        }
        for device in s.audio.outputs {
            list.append(Command(id: "Output: \(device.name)", icon: "hifispeaker") { s.audio.setOutput(device) })
        }
        for position in WindowSnapper.Position.allCases {
            list.append(Command(id: "Window: \(position.rawValue)", icon: "rectangle.split.2x1") { WindowSnapper.snap(position) })
        }
        for snippet in s.snippets.snippets {
            list.append(Command(id: "Snippet: \(snippet.title)", icon: "text.quote") { s.snippets.copy(snippet) })
        }
        for tab in IslandTab.allCases {
            list.append(Command(id: "Show \(tab.title) Tab", icon: tab.icon) { controller.open(tab: tab) })
        }
        return list
    }

    private var filtered: [Command] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return commands }
        var matches = commands.filter { $0.id.localizedCaseInsensitiveContains(q) }
        if let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let url = URL(string: "https://duckduckgo.com/?q=\(encoded)") {
            matches.append(Command(id: "Search the web for “\(q)”", icon: "magnifyingglass") { NSWorkspace.shared.open(url) })
        }
        matches.append(Command(id: "Translate “\(q)”", icon: "translate") {
            TranslateRequest.shared.text = q
            NotchController.current?.expand(sticky: true)
            TranslateRequest.shared.show = true
        })
        if let value = Calculator.evaluate(q) {
            matches.insert(Command(id: "= \(Calculator.format(value))", icon: "equal.circle") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(value), forType: .string)
            }, at: 0)
        }
        return matches
    }

    var body: some View {
        let items = filtered
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onChange(of: query) { _ in selection = 0 }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, cmd in
                        HStack {
                            Image(systemName: cmd.icon).frame(width: 20)
                            Text(cmd.id)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(i == selection ? 0.14 : 0)))
                        .contentShape(Rectangle())
                        .onTapGesture { selection = i; run(items) }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear { query = ""; selection = 0; focused = true; AppState.shared.launcher.load(); AppState.shared.shortcuts.load() }
        .onExitCommand { controller.closeCommandPalette() }
        .background(arrowKeys(count: items.count))
    }

    private func run(_ items: [Command]) {
        guard items.indices.contains(selection) else { return }
        let cmd = items[selection]
        controller.closeCommandPalette()
        cmd.run()
    }

    /// Hidden buttons give the text field ↑/↓ navigation on macOS 13.
    private func arrowKeys(count: Int) -> some View {
        ZStack {
            Button("") { selection = max(0, selection - 1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { selection = min(count - 1, selection + 1) }.keyboardShortcut(.downArrow, modifiers: [])
        }
        .opacity(0)
    }
}
