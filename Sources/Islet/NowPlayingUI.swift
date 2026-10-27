import AppKit
import SwiftUI

// Island-sized Now Playing views built on Lyrical's model and components.

struct NowPlayingCard: View {
    private var model: NowPlayingModel { .shared }
    @AppStorage(Pref.squareArt.rawValue) private var squareArt = false
    @State private var hoveringArt = false

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(image: model.artwork, cornerRadius: squareArt ? 3 : 14, palette: model.palette)
                .frame(width: 112, height: 112)
                .shadow(color: model.accent.opacity(model.isPlaying ? 0.6 : 0.2), radius: model.isPlaying ? 18 : 6, y: 6)
                .scaleEffect(model.isPlaying ? (hoveringArt ? 1.02 : 1) : 0.94)
                .animation(Motion.standard, value: model.isPlaying)
                .animation(Motion.standard, value: hoveringArt)
                .id(model.track?.id)
                .transition(.blurReplace)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .adaptiveGlass(.clear, in: .circle)
                        .padding(6)
                        .opacity(hoveringArt ? 1 : 0)
                        .scaleEffect(hoveringArt ? 1 : 0.5)
                }
                .onHover { hoveringArt = $0 }
                .onTapGesture { FullScreenLyrics.shared.show() }
                .help("Full-screen lyrics")

            VStack(alignment: .leading, spacing: 3) {
                if let track = model.track {
                    HStack(alignment: .firstTextBaseline) {
                        MarqueeText(text: track.title, font: .system(size: 15, weight: .bold))
                        Spacer(minLength: 6)
                        ExtraControls()
                        if let source = model.source {
                            Image(systemName: source.symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .help(source.title)
                        }
                    }
                    Text(track.artist).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    MiniLyricLine()
                        .frame(height: 20)
                    Spacer(minLength: 0)
                    PlaybackProgressView()
                        .scaleEffect(0.92, anchor: .leading)
                    if model.canControl {
                        CompactTransport()
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Text("Nothing playing").font(.headline)
                    Text("Play something in Music, Spotify, Kaset or YouTube Music")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { model.playDefault() } label: {
                        Label("Play", systemImage: "play.fill").padding(.horizontal, 12).padding(.vertical, 5)
                    }
                    .buttonStyle(BouncyButtonStyle())
                    .adaptiveGlass(.clear.interactive(), in: .capsule)
                    .padding(.top, 4)
                    if UserDefaults.standard.bool(forKey: Prefs.shazamEnabled) {
                        Label(model.shazamStatus.label, systemImage: "shazam.logo.fill")
                            .font(.system(size: 10)).foregroundStyle(model.shazamStatus.tint)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .background {
            ZStack {
                cardBackground
                LinearGradient(colors: [model.accent.opacity(model.track == nil ? 0 : 0.35), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .animation(.smooth(duration: 0.8), value: model.track?.id)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: model.track?.id)
    }
}

/// The current lyric line, sweeping left to right as it's sung.
struct MiniLyricLine: View {
    private var model: NowPlayingModel { .shared }
    @AppStorage(Prefs.syncOffset) private var syncOffset = 0.0
    @AppStorage(Prefs.karaokeSweep) private var karaokeSweep = true

    var body: some View {
        if let lines = model.lyrics.syncedLines {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !model.isPlaying)) { context in
                let time = model.time(at: context.date) + syncOffset
                let index = lines.activeIndex(at: time)
                Group {
                    if let index, !lines[index].isGap {
                        let text = Text(lines[index].text).font(.system(size: 13, weight: .bold))
                        if #available(macOS 15, *), karaokeSweep {
                            text.foregroundStyle(.white)
                                .textRenderer(KaraokeRenderer(progress: lines.sweepProgress(at: index, time: time),
                                                              litOpacity: 1, dimOpacity: 0.35, feather: 14))
                        } else {
                            text.foregroundStyle(model.accent)
                        }
                    } else {
                        InstrumentalDots(size: 5)
                    }
                }
                .lineLimit(1)
                .id(index ?? -1)
                .transition(.asymmetric(insertion: .push(from: .bottom), removal: .push(from: .bottom)).combined(with: .opacity))
                .animation(Motion.standard, value: index)
            }
        }
    }
}

struct CompactTransport: View {
    private var model: NowPlayingModel { .shared }

    var body: some View {
        AdaptiveGlassContainer(spacing: 10) {
            HStack(spacing: 16) {
                button("backward.fill", size: 12, diameter: 30) { model.previous() }
                button(model.isPlaying ? "pause.fill" : "play.fill", size: 16, diameter: 38) { model.togglePlayPause() }
                button("forward.fill", size: 12, diameter: 30) { model.next() }
            }
        }
    }

    private func button(_ symbol: String, size: CGFloat, diameter: CGFloat, action: @escaping () -> Void) -> some View {
        BouncyButton(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .adaptiveGlass(.clear.interactive(), in: .circle)
    }
}

struct LyricsTab: View {
    private var model: NowPlayingModel { .shared }
    @ObservedObject private var history = AppState.shared.history
    @State private var showHistory = false

    var body: some View {
        Group {
            if showHistory {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(history.entries) { e in
                            HStack {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(e.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(e.artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(e.date, style: .relative).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        if history.entries.isEmpty { Text("Songs you play will be listed here").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            } else {
            switch model.lyrics {
            case .synced, .plain:
                LyricsPane(fontSize: 18)
            case .loading:
                ProgressView().controlSize(.small)
            case .instrumental:
                InstrumentalDots(size: 10)
            case .unavailable:
                message("No lyrics found for this song", "quote.bubble")
            case .idle:
                message("Play a song to see its lyrics", "music.note")
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            // Both controls share the top-right corner so they never cover the lyrics.
            VStack(spacing: 6) {
                Button { showHistory.toggle() } label: {
                    Image(systemName: showHistory ? "quote.bubble" : "clock.arrow.circlepath").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26)
                }
                .buttonStyle(BouncyButtonStyle())
                .adaptiveGlass(.clear.interactive(), in: .circle)
                .help(showHistory ? "Lyrics" : "Listening history")
                if model.track != nil {
                    BouncyButton { FullScreenLyrics.shared.show() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                    }
                    .adaptiveGlass(.clear.interactive(), in: .circle)
                    .help("Full-screen lyrics")
                }
            }
        }
    }

    private func message(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
    }
}

/// A plain button that squishes when pressed and springs back.
struct BouncyButton<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action, label: label).buttonStyle(BouncyButtonStyle())
    }
}

struct BouncyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Lyrical's full-screen player, shown over the current screen.
@MainActor
final class FullScreenLyrics {
    static let shared = FullScreenLyrics()
    private var window: FullScreenWindow?
    private var keyMonitor: Any?

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let root = FullScreenLyricsView(onClose: { [weak self] in self?.hide() })
            .environment(NowPlayingModel.shared)
        let window = FullScreenWindow(screen: screen, content: root)
        window.alphaValue = 0
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        let model = NowPlayingModel.shared
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.window != nil else { return event }
            switch event.keyCode {
            case 53: self?.hide(); return nil                                    // esc
            case 49: model.togglePlayPause(); return nil                         // space
            case 124 where event.modifierFlags.contains(.command): model.next(); return nil
            case 123 where event.modifierFlags.contains(.command): model.previous(); return nil
            default: return event
            }
        }
        self.window = window
    }

    func hide() {
        guard let window else { return }
        self.window = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSCursor.setHiddenUntilMouseMoves(false)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; window.animator().alphaValue = 0 }) {
            Task { @MainActor in window.orderOut(nil) }
        }
    }
}

final class FullScreenWindow: NSWindow {
    init(screen: NSScreen, content: some View) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .statusBar
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        backgroundColor = .black
        isOpaque = true
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Extra transport: shuffle, repeat, skip, speed

extension NowPlayingModel {
    private func script(for source: PlaybackSource, spotify: String, music: String, kaset: String) -> String? {
        switch source {
        case .spotify: return "tell application id \"com.spotify.client\" to \(spotify)"
        case .appleMusic: return "tell application id \"com.apple.Music\"\n\(music)\nend tell"
        case .kaset: return "tell application id \"com.sertacozercan.Kaset\" to \(kaset)"
        default: return nil
        }
    }

    var supportsShuffle: Bool { [.spotify, .appleMusic, .kaset].contains(source) }
    var isBrowser: Bool { source == .youTubeMusicChrome || source == .youTubeMusicSafari }

    func toggleShuffle() {
        guard let source, let s = script(for: source, spotify: "set shuffling to not shuffling",
                                         music: "set shuffle enabled to not shuffle enabled", kaset: "toggle shuffle") else { return }
        bridge.run(s)
        AppState.shared.hud.show(icon: "shuffle", text: "Shuffle toggled")
    }

    func cycleRepeat() {
        guard let source, let s = script(for: source, spotify: "set repeating to not repeating",
                                         music: "if song repeat is off then\nset song repeat to all\nelse if song repeat is all then\nset song repeat to one\nelse\nset song repeat to off\nend if",
                                         kaset: "cycle repeat") else { return }
        bridge.run(s)
        AppState.shared.hud.show(icon: "repeat", text: "Repeat changed")
    }

    /// ±15 s (Settings → Now Playing) — handy for podcasts and audiobooks.
    func skip(by seconds: Double) {
        guard canSeek else { return }
        seek(to: max(0, time(at: Date()) + seconds))
    }

    /// Playback speed for YouTube Music / video in Chrome or Safari.
    func setSpeed(_ rate: Double) {
        guard let source, isBrowser else { return }
        let id = source == .youTubeMusicChrome ? MediaAppBridge.chromeID : MediaAppBridge.safariID
        bridge.run(MediaAppBridge.browserScript(bundleID: id, js: "(function(){var v=document.querySelector('video');if(v)v.playbackRate=\(rate);return 1})()"))
        AppState.shared.hud.show(icon: "gauge.with.dots.needle.67percent", text: "\(rate)×")
    }

    /// Starts the preferred player when nothing is playing.
    func playDefault() {
        let id = Pref.defaultPlayer.string
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.bridge.run("tell application id \"\(id)\" to play")
        }
    }
}

struct ExtraControls: View {
    private var model: NowPlayingModel { .shared }
    @AppStorage(Pref.skipSeconds.rawValue) private var skip = 15

    var body: some View {
        HStack(spacing: 2) {
            if model.canSeek {
                small("gobackward.\(skip == 30 ? 30 : skip == 10 ? 10 : 15)") { model.skip(by: -Double(skip)) }
                small("goforward.\(skip == 30 ? 30 : skip == 10 ? 10 : 15)") { model.skip(by: Double(skip)) }
            }
            if model.supportsShuffle {
                small("shuffle") { model.toggleShuffle() }
                small("repeat") { model.cycleRepeat() }
            }
            if model.isBrowser {
                Menu {
                    ForEach([1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in Button("\(r, specifier: "%g")×") { model.setSpeed(r) } }
                } label: { Image(systemName: "gauge.with.dots.needle.50percent") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    private func small(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(BouncyButtonStyle())
    }
}

/// A title that slowly scrolls when it's too long to fit (Settings → Now Playing → Scroll long titles).
struct MarqueeText: View {
    let text: String
    let font: Font
    @AppStorage(Pref.marquee.rawValue) private var enabled = true
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth - geo.size.width
            if enabled, overflow > 2 {
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    // Pause at each end, scroll at ~30 pt/s.
                    let travel = Double(overflow)
                    let cycle = travel / 30 * 2 + 4
                    let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
                    let x = t < 2 ? 0 : t < 2 + travel / 30 ? (t - 2) * 30 : t < 4 + travel / 30 ? travel : max(0, travel - (t - 4 - travel / 30) * 30)
                    Text(text).font(font).fixedSize().offset(x: -x)
                }
                .frame(width: geo.size.width, alignment: .leading)
                .clipped()
            } else {
                Text(text).font(font).lineLimit(1)
            }
        }
        .frame(height: 20)
        .background(Text(text).font(font).fixedSize().hidden().onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 })
    }
}
