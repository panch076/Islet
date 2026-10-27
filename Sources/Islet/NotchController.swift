import AppKit
import ApplicationServices
import Combine
import SwiftUI

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum IslandTab: String, CaseIterable, Identifiable {
    case home, lyrics, sound, clipboard, shelf, notes, timer, stats, ai, ask, widgets, pet, tools, terminal
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .lyrics: return "quote.bubble.fill"
        case .sound: return "speaker.wave.2.fill"
        case .clipboard: return "doc.on.clipboard"
        case .shelf: return "tray.full.fill"
        case .notes: return "note.text"
        case .timer: return "timer"
        case .stats: return "cpu"
        case .ai: return "sparkles"
        case .ask: return "bubble.left.and.text.bubble.right.fill"
        case .widgets: return "cloud.sun.fill"
        case .pet: return "pawprint.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .terminal: return "terminal.fill"
        }
    }

    var title: String {
        switch self {
        case .ai: return "AI Usage"
        case .ask: return "Ask AI"
        case .timer: return "Pomodoro"
        default: return rawValue.capitalized
        }
    }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var expanded = false
    /// A small preview (mini player) shown on a quick hover, before the full island opens.
    @Published var peeking = false
    @Published var hasNotch = false
    @Published var notchSize = CGSize(width: 160, height: 30)
    @Published var collapsedSize = CGSize(width: 130, height: 30)
    @Published var tab: IslandTab = .home
    @Published var paletteOpen = false
    @Published var hidden = false
    /// "Invisible Until Hover": the idle pill fades out until the pointer reaches it.
    @Published var invisible = false
    @Published var contentSize = CGSize(width: Pref.panelWidth.double, height: Pref.panelHeight.double)
    @Published var topOffset: CGFloat = 4
    /// What the collapsed pill shows; computed once per tick and only published when it changes.
    @Published var activity: AppState.Activity = .none
    @Published var secondary: AppState.Activity?

    var expandedSize: CGSize {
        CGSize(width: contentSize.width, height: contentSize.height + (hasNotch ? notchSize.height : 0))
    }
    // Never narrower than the collapsed pill, or the pointer would fall outside it and the peek would flicker.
    var peekSize: CGSize { CGSize(width: max(380, collapsedSize.width), height: (hasNotch ? notchSize.height : 0) + 74) }
    var size: CGSize { expanded ? expandedSize : peeking ? peekSize : collapsedSize }
    /// Pill mode floats slightly below the top edge; notch mode hugs it.
    var topInset: CGFloat { hasNotch ? 0 : topOffset }
}

@MainActor
final class NotchController {
    static weak var current: NotchController?

    let state = NotchState()
    private var panel: IslandPanel!
    private var timer: Timer?
    private var hoverSince: Date?
    private var outsideSince: Date?
    private var stickyUntil = Date.distantPast
    private var lastDragCount = NSPasteboard(name: .drag).changeCount
    private var swipeHandled = false
    private var scrollMonitor: Any?
    private var defaultsObserver: Any?
    private var resignObserver: Any?
    private var capsLock = NSEvent.modifierFlags.contains(.capsLock)
    private var detached = false
    private var lastFullscreenCheck = Date.distantPast
    private var coveredByFullscreen = false
    private let windowSize = CGSize(width: 900, height: 400)

    /// nil only during display reconfiguration, when macOS briefly reports no screens.
    private var screen: NSScreen? {
        let target = Pref.targetDisplay.string
        if target != "auto", let s = NSScreen.screens.first(where: { $0.localizedName == target }) { return s }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    /// Spring used for opening/closing, from Settings → Island → Animation.
    private var openAnimation: Animation {
        Motion.open
    }

    func show() {
        Self.current = self
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: IslandRootView(state: state, controller: self).environment(NowPlayingModel.shared))
        // The panel has a fixed size; skip SwiftUI's intrinsic-size constraints (a layout pass on every update).
        host.sizingOptions = []
        panel.contentView = host
        applyPrefs()
        panel.orderFrontRegardless()

        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.paletteOpen else { return }
                self.closeCommandPalette()
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPrefs() }
        }
    }

    /// Re-reads island preferences; cheap enough to run on every defaults change.
    private func applyPrefs() {
        panel.sharingType = Pref.hideFromCapture.bool ? .none : .readOnly
        let size = CGSize(width: Pref.panelWidth.double, height: Pref.panelHeight.double)
        if size != state.contentSize {
            withAnimation(openAnimation) { state.contentSize = size }
            // Live preview while the user drags the size sliders.
            expand(sticky: true)
        }
        if state.topOffset != Pref.pillOffset.double { state.topOffset = Pref.pillOffset.double }
        reposition()
    }

    /// Gestures on the collapsed island: swipe down opens it, swipe sideways skips tracks.
    private func handleScroll(_ e: NSEvent) {
        guard AppState.shared.settings.gestures, !state.expanded, e.hasPreciseScrollingDeltas else { return }
        if e.phase == .began { swipeHandled = false }
        guard !swipeHandled, e.momentumPhase == [] else { return }
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if abs(dy) > abs(dx), dy > 6, Pref.gestureSwipeOpen.bool {
            swipeHandled = true
            expand(sticky: true)
        } else if abs(dx) > 12, Pref.gestureSkip.bool, AppState.shared.nowPlaying.canControl {
            swipeHandled = true
            dx < 0 ? AppState.shared.nowPlaying.next() : AppState.shared.nowPlaying.previous()
        }
    }

    func reposition() {
        guard panel != nil, let s = screen else { return }
        let notched = s.safeAreaInsets.top > 0 && !Pref.pillOnNotch.bool
        if state.hasNotch != notched { state.hasNotch = notched }
        let notch: CGSize
        if notched, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            notch = CGSize(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
        } else {
            notch = CGSize(width: 130, height: max(22, 30 + Pref.pillHeight.double))
        }
        if state.notchSize != notch { state.notchSize = notch }
        let frame = NSRect(x: s.frame.midX - windowSize.width / 2, y: s.frame.maxY - windowSize.height,
                           width: windowSize.width, height: windowSize.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        updateCollapsedSize()
    }

    // MARK: Expand / collapse

    func expand(sticky: Bool = false, resetTab: Bool = false) {
        if sticky { stickyUntil = Date().addingTimeInterval(3) }
        guard !state.expanded, !detached else { return }
        // Opening while a full-screen app hid the island: show it, or it would open invisibly.
        if state.hidden {
            state.hidden = false
            coveredByFullscreen = false
            panel.alphaValue = 1
        }
        if resetTab, Pref.defaultTab.string != "last", let tab = IslandTab(rawValue: Pref.defaultTab.string) {
            state.tab = tab
        }
        withAnimation(openAnimation) {
            state.peeking = false
            state.expanded = true
        }
    }

    func collapse() {
        guard state.expanded || state.peeking else { return }
        withAnimation(Motion.close) {
            state.expanded = false
            state.peeking = false
            state.paletteOpen = false
        }
        // Give keyboard focus back to whatever app was in front.
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    func toggle() { state.expanded ? collapse() : expand(sticky: true) }

    func open(tab: IslandTab) {
        state.tab = tab
        expand(sticky: true)
    }

    func openCommandPalette() {
        guard !detached else { return }
        expand(sticky: true)
        state.paletteOpen = true
        panel.ignoresMouseEvents = false
        panel.makeKey()
    }

    func closeCommandPalette() {
        state.paletteOpen = false
        if !islandRect().contains(NSEvent.mouseLocation) { collapse() }
    }

    /// With "Menu Bar Detach" the island lives in a menu bar popover and the notch stays empty.
    func setDetached(_ on: Bool) {
        detached = on
        if on { collapse() }
        panel.alphaValue = on ? 0 : 1
    }

    // MARK: Tracking

    private func islandRect() -> NSRect {
        let size = state.size
        let f = panel.frame
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - state.topInset - size.height,
                      width: size.width, height: size.height)
    }

    private func updateCollapsedSize() {
        let h = state.notchSize.height
        let app = AppState.shared
        let activity = app.activity
        let secondary = app.secondaryActivity
        if state.activity != activity { state.activity = activity }
        if state.secondary != secondary { state.secondary = secondary }
        let active = activity != .none || (!state.hasNotch && app.idleNeedsSpace)
        let extra: CGFloat = secondary != nil ? 56 : 0
        let size: CGSize
        if state.hasNotch {
            size = CGSize(width: state.notchSize.width + (active ? 2 * (h + 46) : 0) + extra, height: h)
        } else {
            size = CGSize(width: (active ? 300 : 130) + extra, height: h)
        }
        if size != state.collapsedSize {
            withAnimation(Motion.standard) { state.collapsedSize = size }
        }
    }

    private func tick() {
        updateCollapsedSize()
        checkCapsLock()
        checkFullscreen()
        if detached { return }

        // An agent waiting for approval pops the island open until it's answered.
        if AppState.shared.agents.pendingApproval != nil, !state.expanded {
            state.tab = .home
            expand(sticky: true)
        }

        let mouse = NSEvent.mouseLocation
        let near = islandRect().insetBy(dx: -4, dy: -4).contains(mouse)
        let inside = !state.hidden && near
        let invisible = Pref.invisibleUntilHover.bool && !near && !state.expanded && !state.peeking && state.activity == .none
        if invisible != state.invisible { withAnimation(Motion.standard) { state.invisible = invisible } }
        panel.ignoresMouseEvents = !(inside || (state.paletteOpen && panel.isKeyWindow))

        // A file drag started when the drag pasteboard changed while the button is held.
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        let dragCount = NSPasteboard(name: .drag).changeCount
        let fileDrag = buttonDown && dragCount != lastDragCount
        if !buttonDown { lastDragCount = dragCount }

        if !state.expanded {
            guard inside else {
                hoverSince = nil
                if state.peeking { collapse() }
                return
            }
            if hoverSince == nil { hoverSince = Date() }
            let hovered = Date().timeIntervalSince(hoverSince!)
            let settings = AppState.shared.settings
            if fileDrag {
                state.tab = .shelf
                expand()
            } else if !buttonDown, settings.hoverToOpen {
                let canPeek = Pref.peekOnHover.bool && AppState.shared.nowPlaying.track != nil
                if canPeek, !state.peeking, hovered > Pref.peekDelay.double {
                    withAnimation(Motion.open) { state.peeking = true }
                } else if hovered > settings.hoverDelay + (canPeek ? 0.6 : 0), !Pref.doubleClickOpen.bool {
                    expand(resetTab: true)
                }
            }
        } else if inside || state.paletteOpen || Date() < stickyUntil || AppState.shared.agents.pendingApproval != nil {
            outsideSince = nil
        } else {
            if outsideSince == nil { outsideSince = Date() }
            if Date().timeIntervalSince(outsideSince!) > Pref.collapseDelay.double { collapse() }
        }
    }

    /// "Hide if Menus Overlap": the front app's menus reach under the pill (needs Accessibility).
    private func menusOverlap() -> Bool {
        guard Pref.hideIfMenusOverlap.bool, AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app would otherwise block the main thread for the default ~6 s AX timeout.
        AXUIElementSetMessagingTimeout(axApp, 0.1)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement], let last = items.last else { return false }
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(last, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(last, kAXSizeAttribute as CFString, &size) == .success else { return false }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        let menuEnd = p.x + s.width
        let pillStart = islandRect().minX
        guard let frame = screen?.frame else { return false }
        return frame.contains(CGPoint(x: p.x + 1, y: frame.midY)) && menuEnd > pillStart - 8
    }

    private func checkCapsLock() {
        let on = NSEvent.modifierFlags.contains(.capsLock)
        guard on != capsLock else { return }
        capsLock = on
        if Pref.capsLockHUD.bool {
            AppState.shared.hud.show(icon: on ? "capslock.fill" : "capslock", text: on ? "Caps Lock on" : "Caps Lock off", seconds: 1.5)
        }
    }

    /// Hides the island while a full-screen app covers its screen (Settings → Island).
    private func checkFullscreen() {
        guard Date().timeIntervalSince(lastFullscreenCheck) > 1.0 else { return }
        lastFullscreenCheck = Date()
        var covered = !state.expanded && menusOverlap()
        if !covered, Pref.hideInFullscreen.bool, let front = NSWorkspace.shared.frontmostApplication, let s = screen?.frame,
           let primaryHeight = NSScreen.screens.first?.frame.height,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            covered = windows.contains { w in
                guard (w[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier,
                      (w[kCGWindowLayer as String] as? Int) == 0,
                      let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
                // Window bounds use a top-left origin; flip to compare with the screen frame.
                let rect = CGRect(x: b["X"] ?? 0, y: primaryHeight - (b["Y"] ?? 0) - (b["Height"] ?? 0),
                                  width: b["Width"] ?? 0, height: b["Height"] ?? 0)
                return rect.equalTo(s)
            }
        }
        // Never hide an open island or one asking for an agent approval.
        if state.expanded || AppState.shared.agents.pendingApproval != nil { covered = false }
        guard covered != coveredByFullscreen else { return }
        coveredByFullscreen = covered
        state.hidden = covered
        if covered { collapse() }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = covered || detached ? 0 : 1 }
    }
}
