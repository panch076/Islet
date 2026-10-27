import SwiftUI

struct FullScreenLyricsView: View {
    @Environment(NowPlayingModel.self) private var model
    @AppStorage(Prefs.fontScale) private var fontScale = 1.0

    var onClose: () -> Void

    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?

    private var hasLyrics: Bool {
        switch model.lyrics {
        case .synced, .plain: true
        default: false
        }
    }

    var body: some View {
        GeometryReader { geo in
            let paneWidth = min(geo.size.width * (hasLyrics ? 0.3 : 0.34), 560)
            ZStack {
                AnimatedArtworkBackground(image: model.artwork, palette: model.palette, trackID: model.track?.id)

                HStack(alignment: .center, spacing: geo.size.width * 0.07) {
                    if hasLyrics {
                        NowPlayingPane(width: paneWidth)
                        LyricsPane(fontSize: max(30, geo.size.width / 40) * fontScale)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    } else {
                        Spacer(minLength: 0)
                        VStack(spacing: 30) {
                            NowPlayingPane(width: paneWidth)
                            emptyState
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, geo.size.width * 0.07)
                .padding(.vertical, geo.size.height * 0.07)
                .animation(.spring(response: 0.7, dampingFraction: 0.85), value: hasLyrics)
            }
            .overlay(alignment: .topLeading) {
                Button(action: onClose) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .adaptiveGlass(.clear.interactive(), in: .circle)
                .help("Exit Full Screen (esc)")
                .padding(28)
                .opacity(chromeVisible ? 1 : 0)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .onContinuousHover { _ in revealChrome() }
        .onAppear { revealChrome() }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.lyrics {
        case .loading:
            ProgressView().controlSize(.large)
        case .instrumental:
            InstrumentalDots(size: 14)
        case .unavailable:
            Text("Lyrics aren't available for this song")
                .font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
        case .idle:
            Text("Play a song in any app to see lyrics")
                .font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
        default:
            EmptyView()
        }
    }

    private func revealChrome() {
        if !chromeVisible { withAnimation(.easeOut(duration: 0.25)) { chromeVisible = true } }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.6)) { chromeVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

// MARK: - Now playing column

struct NowPlayingPane: View {
    @Environment(NowPlayingModel.self) private var model
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(image: model.artwork, cornerRadius: width * 0.035, palette: model.palette)
                .frame(width: width, height: width)
                .shadow(color: .black.opacity(0.45), radius: 40, y: 24)
                .scaleEffect(model.isPlaying ? 1 : 0.88)
                .animation(.spring(response: 0.55, dampingFraction: 0.68), value: model.isPlaying)
                .id(model.track?.id)
                .transition(.blurReplace)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.track?.title ?? "Not Playing")
                        .font(.system(size: 24, weight: .bold))
                        .lineLimit(2)
                    Text(model.track?.artist ?? " ")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if let source = model.source {
                    SourceBadge(source: source)
                }
            }
            .padding(.top, 34)

            PlaybackProgressView()
                .padding(.top, 22)

            if model.canControl {
                TransportControls()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 22)
            }
        }
        .frame(width: width)
    }
}

struct PlaybackProgressView: View {
    @Environment(NowPlayingModel.self) private var model
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let duration = model.track?.duration ?? 0
            let time = model.time(at: context.date)
            let fraction = dragFraction ?? (duration > 0 ? min(max(time / duration, 0), 1) : 0)
            let shown = duration > 0 ? fraction * duration : time

            VStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white.opacity(dragFraction == nil ? 0.75 : 0.95))
                            .frame(width: max(geo.size.width * fraction, 0))
                    }
                    .frame(height: dragFraction == nil ? 6 : 10)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard model.canSeek, duration > 0 else { return }
                                dragFraction = min(max(value.location.x / geo.size.width, 0), 1)
                            }
                            .onEnded { _ in
                                if let dragFraction { model.seek(to: dragFraction * duration) }
                                dragFraction = nil
                            }
                    )
                    .animation(.spring(response: 0.25), value: dragFraction == nil)
                }
                .frame(height: 14)

                HStack {
                    Text(formatTime(shown))
                    Spacer()
                    if duration > 0 { Text("-" + formatTime(duration - shown)) }
                }
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

struct TransportControls: View {
    @Environment(NowPlayingModel.self) private var model

    var body: some View {
        AdaptiveGlassContainer(spacing: 20) {
            HStack(spacing: 26) {
                button("backward.fill", size: 20, diameter: 56) { model.previous() }
                button(model.isPlaying ? "pause.fill" : "play.fill", size: 30, diameter: 76) { model.togglePlayPause() }
                button("forward.fill", size: 20, diameter: 56) { model.next() }
            }
        }
    }

    private func button(_ symbol: String, size: CGFloat, diameter: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .adaptiveGlass(.clear.interactive(), in: .circle)
    }
}

// MARK: - Lyrics column

struct LyricsPane: View {
    @Environment(NowPlayingModel.self) private var model
    @AppStorage(Prefs.syncOffset) private var syncOffset = 0.0
    let fontSize: CGFloat

    var body: some View {
        switch model.lyrics {
        case .synced(let lines):
            TimelineView(.animation(minimumInterval: 1 / 20, paused: !model.isPlaying)) { context in
                let time = model.time(at: context.date) + syncOffset
                SyncedLyricsList(
                    lines: lines,
                    activeIndex: lines.activeIndex(at: time),
                    fontSize: fontSize,
                    canSeek: model.canSeek,
                    onSeek: { model.seek(to: $0 - syncOffset + 0.02) }
                )
                .equatable()
            }
        case .plain(let lines):
            PlainLyricsList(lines: lines, fontSize: fontSize * 0.8)
        default:
            EmptyView()
        }
    }
}

/// Apple Music-style lyric column. Rather than scrolling a ScrollView, every
/// row is offset so the active line sits at 30% height, and rows below the
/// active line start moving slightly later, producing a cascading roll.
struct SyncedLyricsList: View, Equatable {
    let lines: [LyricLine]
    let activeIndex: Int?
    let fontSize: CGFloat
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.activeIndex == b.activeIndex && a.fontSize == b.fontSize && a.canSeek == b.canSeek && a.lines == b.lines
    }

    @State private var heights: [Int: CGFloat] = [:]

    private static let introID = -1
    private var hasIntro: Bool { (lines.first?.time ?? 0) > 3 }
    private var spacing: CGFloat { fontSize * 0.45 }
    private var rowIDs: [Int] { (hasIntro ? [Self.introID] : []) + lines.map(\.id) }
    private var focusID: Int { activeIndex ?? (hasIntro ? Self.introID : lines.first?.id ?? 0) }

    private func top(of id: Int) -> CGFloat {
        var y: CGFloat = 0
        for rowID in rowIDs {
            if rowID == id { break }
            y += (heights[rowID] ?? fontSize * 1.4) + spacing
        }
        return y
    }

    private func delay(forRowAt position: Int, focusPosition: Int) -> Double {
        let distance = position - focusPosition + 1
        return Double(min(max(distance, 0), 8)) * 0.04
    }

    var body: some View {
        GeometryReader { geo in
            let ids = rowIDs
            let focusPosition = ids.firstIndex(of: focusID) ?? 0
            let offset = geo.size.height * 0.3 - top(of: focusID)

            VStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(ids.enumerated()), id: \.element) { position, id in
                    row(for: id)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[id] = $0 }
                        .offset(y: offset)
                        .animation(
                            .spring(response: 0.75, dampingFraction: 0.86)
                                .delay(delay(forRowAt: position, focusPosition: focusPosition)),
                            value: focusID)
                }
            }
            .padding(.trailing, 24)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .clipped()
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.14),
                .init(color: .black, location: 0.8),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
    }

    @ViewBuilder
    private func row(for id: Int) -> some View {
        if id == Self.introID {
            InstrumentalDots(size: fontSize * 0.3)
                .frame(height: fontSize * 1.1)
                .opacity(activeIndex == nil ? 1 : 0.3)
                .padding(.horizontal, 18)
        } else {
            LyricRow(line: lines[id], lines: lines, activeIndex: activeIndex, fontSize: fontSize, canSeek: canSeek, onSeek: onSeek)
        }
    }
}

struct LyricRow: View {
    let line: LyricLine
    let lines: [LyricLine]
    let activeIndex: Int?
    let fontSize: CGFloat
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void

    @State private var hovering = false

    private var isActive: Bool { activeIndex == line.id }
    private var distance: Int { abs(line.id - (activeIndex ?? -1)) }

    var body: some View {
        Group {
            if line.isGap {
                // Fixed height keeps the layout stable, so rows never jump.
                InstrumentalDots(size: fontSize * 0.3)
                    .frame(height: fontSize * 1.1)
                    .opacity(isActive ? 1 : 0.25)
            } else {
                SungLyricText(line: line, lines: lines, fontSize: fontSize,
                              isActive: isActive, isPast: line.id < (activeIndex ?? -1))
                    .shadow(color: .white.opacity(isActive ? 0.25 : 0), radius: 12)
            }
        }
        .blur(radius: isActive || hovering ? 0 : min(CGFloat(distance) * 0.8, 4.5))
        .scaleEffect(isActive ? 1 : 0.95, anchor: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(hovering && canSeek && !line.isGap ? 0.1 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .onTapGesture { if canSeek { onSeek(line.time) } }
        .animation(.easeInOut(duration: 0.5), value: isActive)
    }
}

/// A full-screen lyric line that lights up as it's sung. Only the active line
/// runs a timeline; the others render once, so the list itself stays still.
struct SungLyricText: View {
    @Environment(NowPlayingModel.self) private var model
    @AppStorage(Prefs.syncOffset) private var syncOffset = 0.0
    @AppStorage(Prefs.karaokeSweep) private var karaokeSweep = true

    let line: LyricLine
    let lines: [LyricLine]
    let fontSize: CGFloat
    let isActive: Bool
    let isPast: Bool

    private static let dimOpacity = 0.32

    var body: some View {
        // One TimelineView in every state keeps the view's identity stable, so
        // the brightness fade animates when a line becomes active or finishes.
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !(isActive && model.isPlaying))) { context in
            let text = Text(line.text).font(.system(size: fontSize, weight: .bold))
            Group {
                if #available(macOS 15, *), karaokeSweep {
                    text
                        .foregroundStyle(.white)
                        .textRenderer(KaraokeRenderer(
                            progress: progress(at: context.date),
                            litOpacity: isActive ? 1 : Self.dimOpacity,
                            dimOpacity: Self.dimOpacity,
                            feather: fontSize * 0.7))
                } else {
                    text.foregroundStyle(.white.opacity(isActive ? 1 : Self.dimOpacity))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progress(at date: Date) -> Double {
        if isPast { return 1 }
        guard isActive else { return 0 }
        return lines.sweepProgress(at: line.id, time: model.time(at: date) + syncOffset)
    }
}

struct PlainLyricsList: View {
    let lines: [String]
    let fontSize: CGFloat

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: fontSize * 0.35) {
                Label("These lyrics aren't time-synced", systemImage: "text.alignleft")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 20)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.vertical, 80)
            .padding(.horizontal, 18)
        }
        .scrollIndicators(.hidden)
    }
}
