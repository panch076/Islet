import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Network

// MARK: - Settings

@MainActor
final class SettingsModel: ObservableObject {
    enum PanelSize: String, CaseIterable, Identifiable {
        case compact, standard, large
        var id: String { rawValue }
        var size: CGSize {
            switch self {
            case .compact: return CGSize(width: 560, height: 210)
            case .standard: return CGSize(width: 640, height: 230)
            case .large: return CGSize(width: 740, height: 270)
            }
        }
    }

    private let d = UserDefaults.standard

    @Published var hoverToOpen: Bool { didSet { d.set(hoverToOpen, forKey: "hoverToOpen") } }
    @Published var hoverDelay: Double { didSet { d.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var panelSize: PanelSize { didSet { d.set(panelSize.rawValue, forKey: "panelSize") } }
    @Published var gestures: Bool { didSet { d.set(gestures, forKey: "gestures") } }
    @Published var volumeHUD: Bool { didSet { d.set(volumeHUD, forKey: "volumeHUD") } }
    @Published var downloadAlerts: Bool {
        didSet { d.set(downloadAlerts, forKey: "downloadAlerts"); AppState.shared.downloads.setEnabled(downloadAlerts) }
    }
    @Published var windowSnapping: Bool { didSet { d.set(windowSnapping, forKey: "windowSnapping") } }
    @Published var localAPI: Bool {
        didSet { d.set(localAPI, forKey: "localAPI"); AppState.shared.api.setEnabled(localAPI) }
    }
    @Published var aiDailyTokenAlert: Int { didSet { d.set(aiDailyTokenAlert, forKey: "aiDailyTokenAlert") } }

    enum IslandStyle: String, CaseIterable, Identifiable {
        case black, glass
        var id: String { rawValue }
    }

    @Published var islandStyle: IslandStyle { didSet { d.set(islandStyle.rawValue, forKey: "islandStyle") } }
    @Published var replaceSystemHUD: Bool {
        didSet { d.set(replaceSystemHUD, forKey: "replaceSystemHUD"); AppState.shared.mediaKeys.setEnabled(replaceSystemHUD || Pref.mediaKeys.bool) }
    }
    @Published var focusAlerts: Bool { didSet { d.set(focusAlerts, forKey: "focusAlerts") } }
    @Published var callIsland: Bool { didSet { d.set(callIsland, forKey: "callIsland") } }
    @Published var presenceLock: Bool {
        didSet { d.set(presenceLock, forKey: "presenceLock"); AppState.shared.presence.setEnabled(presenceLock) }
    }
    @Published var presenceTimeout: Int { didSet { d.set(presenceTimeout, forKey: "presenceTimeout") } }

    static let apiPort: UInt16 = 47219

    init() {
        d.register(defaults: ["hoverToOpen": true, "hoverDelay": 0.12, "panelSize": PanelSize.standard.rawValue,
                              "gestures": true, "volumeHUD": true, "downloadAlerts": true, "windowSnapping": true,
                              "localAPI": false, "aiDailyTokenAlert": 0, "islandStyle": IslandStyle.black.rawValue,
                              "replaceSystemHUD": false, "focusAlerts": true, "callIsland": true,
                              "presenceLock": false, "presenceTimeout": 60])
        islandStyle = IslandStyle(rawValue: d.string(forKey: "islandStyle") ?? "") ?? .black
        replaceSystemHUD = d.bool(forKey: "replaceSystemHUD")
        focusAlerts = d.bool(forKey: "focusAlerts")
        callIsland = d.bool(forKey: "callIsland")
        presenceLock = d.bool(forKey: "presenceLock")
        presenceTimeout = d.integer(forKey: "presenceTimeout")
        hoverToOpen = d.bool(forKey: "hoverToOpen")
        hoverDelay = d.double(forKey: "hoverDelay")
        panelSize = PanelSize(rawValue: d.string(forKey: "panelSize") ?? "") ?? .standard
        gestures = d.bool(forKey: "gestures")
        volumeHUD = d.bool(forKey: "volumeHUD")
        downloadAlerts = d.bool(forKey: "downloadAlerts")
        windowSnapping = d.bool(forKey: "windowSnapping")
        localAPI = d.bool(forKey: "localAPI")
        aiDailyTokenAlert = d.integer(forKey: "aiDailyTokenAlert")
    }
}

// MARK: - Global hotkeys (Carbon, no Accessibility permission needed)

enum HotKeys {
    @MainActor private static var handlers: [UInt32: @MainActor () -> Void] = [:]
    @MainActor private static var refs: [EventHotKeyRef] = []
    @MainActor private static var installed = false

    @MainActor
    static func register(_ keyCode: Int, _ modifiers: Int, action: @escaping @MainActor () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                Task { @MainActor in HotKeys.handlers[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = UInt32(handlers.count + 1)
        handlers[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4953_4C54), id: id),
                            GetApplicationEventTarget(), 0, &ref)
        if let ref { refs.append(ref) }
    }
}

// MARK: - Window snapping (Accessibility)

enum WindowSnapper {
    enum Position: String, CaseIterable {
        case left = "Left Half", right = "Right Half", maximize = "Maximize", center = "Center"
        case topLeft = "Top Left", topRight = "Top Right", bottomLeft = "Bottom Left", bottomRight = "Bottom Right"
    }

    @MainActor
    static func snap(_ position: Position) {
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
            AppState.shared.hud.show(icon: "lock.fill", text: "Allow Islet in Accessibility settings", seconds: 3)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let window = value as! AXUIElement

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let v = screen.visibleFrame
        var r: CGRect
        switch position {
        case .left: r = CGRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height)
        case .right: r = CGRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height)
        case .maximize: r = v
        case .center: r = CGRect(x: v.minX + v.width / 6, y: v.minY + v.height / 8, width: v.width * 2 / 3, height: v.height * 3 / 4)
        case .topLeft: r = CGRect(x: v.minX, y: v.midY, width: v.width / 2, height: v.height / 2)
        case .topRight: r = CGRect(x: v.midX, y: v.midY, width: v.width / 2, height: v.height / 2)
        case .bottomLeft: r = CGRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height / 2)
        case .bottomRight: r = CGRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height / 2)
        }
        // Accessibility uses top-left origin relative to the primary screen.
        var origin = CGPoint(x: r.minX, y: NSScreen.screens[0].frame.maxY - r.maxY)
        var size = r.size
        if let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        }
    }
}

// MARK: - Local HTTP API on 127.0.0.1 (off by default)

@MainActor
final class LocalAPI {
    private var listener: NWListener?

    func setEnabled(_ on: Bool) {
        listener?.cancel()
        listener = nil
        guard on else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind to loopback only so nothing on the network can reach it.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: SettingsModel.apiPort)!)
        guard let l = try? NWListener(using: params) else {
            AppState.shared.hud.show(icon: "exclamationmark.triangle", text: "Local API couldn't start")
            return
        }
        l.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("Islet local API failed: \(error)")
                Task { @MainActor in AppState.shared.hud.show(icon: "exclamationmark.triangle", text: "Local API port busy") }
            }
        }
        l.newConnectionHandler = { conn in
            conn.start(queue: .main)
            let session = Session()
            conn.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed: MainActor.assumeIsolated { session.onClose?(); session.onClose = nil }
                default: break
                }
            }
            // Drop clients that connect but never send a full request.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if !session.received { conn.cancel() } }
            Self.receive(conn, buffer: Data(), session: session)
        }
        l.start(queue: .main)
        listener = l
    }

    /// Reads until the headers and the whole body (per Content-Length) have arrived.
    /// Per-connection state: whether a full request arrived, and cleanup for when the client goes away.
    private final class Session: @unchecked Sendable {
        var received = false
        var onClose: (() -> Void)?
    }

    nonisolated private static func receive(_ conn: NWConnection, buffer: Data, session: Session) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if let headerEnd {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { $0.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first }
                    .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buffer[headerEnd.upperBound...]
                if body.count >= length || complete || error != nil {
                    session.received = true
                    MainActor.assumeIsolated {
                        guard isTrusted(head) else {
                            conn.cancel()
                            return
                        }
                        handle(head: head, body: Data(body), onClose: { session.onClose = $0 }) { status, json in
                            let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
                            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
                        }
                    }
                    return
                }
            }
            if complete || error != nil || buffer.count > 1_000_000 { conn.cancel(); return }
            receive(conn, buffer: buffer, session: session)
        }
    }

    /// Routes: /status, /notify?text=..&icon=.., /play-pause, /next, /previous, /keep-awake, /pomodoro, /mic,
    /// /agent?agent=Claude&state=working|waiting|done&message=.., /approve (POST hook JSON, answers when decided),
    /// /shell?state=start|end&id=..&cmd=..&code=..
    /// Only local tools (curl, hooks) may call the API: browsers send Origin, and DNS rebinding changes Host.
    static func isTrusted(_ head: String) -> Bool {
        let headers = head.split(separator: "\r\n").dropFirst().map { $0.lowercased() }
        if headers.contains(where: { $0.hasPrefix("origin:") }) { return false }
        guard let host = headers.first(where: { $0.hasPrefix("host:") })?.dropFirst(5).trimmingCharacters(in: .whitespaces) else { return true }
        let port = String(SettingsModel.apiPort)
        return ["127.0.0.1:\(port)", "localhost:\(port)", "127.0.0.1", "localhost"].contains(host)
    }

    static func handle(head: String, body: Data, onClose: (@escaping () -> Void) -> Void = { _ in },
                       respond: @escaping (String, String) -> Void) {
        let firstLine = head.split(separator: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, let comps = URLComponents(string: String(parts[1])) else {
            respond("400 Bad Request", #"{"error":"bad request"}"#)
            return
        }
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let s = AppState.shared
        let ok = { respond("200 OK", #"{"ok":true}"#) }

        switch comps.path {
        case "/status":
            let status: [String: Any] = [
                "playing": s.nowPlaying.isPlaying, "title": s.nowPlaying.track?.title ?? "", "artist": s.nowPlaying.track?.artist ?? "",
                "keepAwake": s.keepAwake.enabled, "pomodoro": ["running": s.pomodoro.running, "remaining": s.pomodoro.remaining],
                "micMuted": s.audio.micMuted, "battery": s.battery.hasBattery ? s.battery.percent : NSNull(),
            ]
            let data = (try? JSONSerialization.data(withJSONObject: status)) ?? Data("{}".utf8)
            respond("200 OK", String(decoding: data, as: UTF8.self))
        case "/notify":
            s.hud.show(icon: q["icon"] ?? "bell.fill", text: q["text"] ?? "Notification", seconds: Double(q["seconds"] ?? "") ?? 3)
            ok()
        case "/open":
            // Opens the island on a tab: /open?tab=tools (useful for scripts and Shortcuts).
            guard let tab = IslandTab(rawValue: q["tab"] ?? "home") else {
                respond("400 Bad Request", #"{"error":"unknown tab"}"#)
                return
            }
            NotchController.current?.open(tab: tab)
            ok()
        case "/close":
            NotchController.current?.collapse()
            ok()
        case "/play-pause": s.nowPlaying.togglePlayPause(); ok()
        case "/next": s.nowPlaying.next(); ok()
        case "/previous": s.nowPlaying.previous(); ok()
        case "/keep-awake": s.keepAwake.toggle(); ok()
        case "/pomodoro": s.pomodoro.toggle(); ok()
        case "/mic": s.audio.toggleMic(); ok()
        case "/screen-light": s.screenLight.toggle(); ok()
        case "/agent":
            guard let state = AgentModel.State(rawValue: q["state"] ?? "") else {
                respond("400 Bad Request", #"{"error":"state must be working, waiting or done"}"#)
                return
            }
            s.agents.update(name: q["agent"] ?? "Agent", state: state, message: q["message"] ?? "")
            ok()
        case "/shell":
            let id = q["id"] ?? "shell"
            if q["state"] == "start" {
                s.shell.start(id: id, command: q["cmd"] ?? "")
            } else {
                s.shell.end(id: id, code: Int(q["code"] ?? "") ?? 0)
            }
            ok()
        case "/approve":
            // Body is the Claude Code hook payload; reply in the format that hook event expects.
            let hook = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            let event = hook["hook_event_name"] as? String ?? "PermissionRequest"
            let tool = hook["tool_name"] as? String ?? "a tool"
            let input = hook["tool_input"] as? [String: Any] ?? [:]
            let detail = (input["command"] ?? input["file_path"] ?? input["url"] ?? input["pattern"]).map { "\($0)" } ?? ""
            let id = s.agents.requestApproval(agent: q["agent"] ?? "Claude", tool: tool, detail: detail) { decision in
                let output: [String: Any]
                if event == "PreToolUse" {
                    output = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": decision.rawValue,
                                                     "permissionDecisionReason": "Answered in Islet"]]
                } else if decision == .ask {
                    output = [:] // no decision: the agent shows its normal prompt
                } else {
                    output = ["hookSpecificOutput": ["hookEventName": event,
                                                     "decision": ["behavior": decision == .allow ? "allow" : "deny",
                                                                  "message": "Answered in Islet"]]]
                }
                let data = (try? JSONSerialization.data(withJSONObject: output)) ?? Data("{}".utf8)
                respond("200 OK", String(decoding: data, as: UTF8.self))
            }
            if let id { onClose { AppState.shared.agents.decide(id, .ask) } }
        default:
            respond("404 Not Found", #"{"error":"unknown route"}"#)
        }
    }
}
