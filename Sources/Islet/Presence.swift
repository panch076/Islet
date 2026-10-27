import AppKit
import AVFoundation
import Vision

// MARK: - Focus mode alerts

/// Reads the Focus database (~/Library/DoNotDisturb). macOS only allows this with Full Disk Access.
@MainActor
final class FocusModel: ObservableObject {
    @Published private(set) var current: String?
    @Published private(set) var accessible = true
    private var initialized = false
    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB")

    func refresh() {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("Assertions.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if accessible { accessible = false }
            return
        }
        if !accessible { accessible = true }
        let records = ((json["data"] as? [[String: Any]])?.first?["storeAssertionRecords"] as? [[String: Any]]) ?? []
        let modeID = (records.first?["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String
        let name = modeID.map { modeName($0) ?? "Focus" }

        if initialized, name != current, AppState.shared.settings.focusAlerts {
            AppState.shared.hud.show(icon: name == nil ? "moon" : "moon.fill",
                                     text: name.map { "\($0) on" } ?? "Focus off", seconds: 2.5)
        }
        if current != name { current = name }
        initialized = true
    }

    private func modeName(_ id: String) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("ModeConfigurations.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let configs = (json["data"] as? [[String: Any]])?.first?["modeConfigurations"] as? [String: Any],
              let mode = (configs[id] as? [String: Any])?["mode"] as? [String: Any] else { return nil }
        return mode["name"] as? String
    }
}

// MARK: - Call island

/// Treats a known calling app using the microphone as an active call.
@MainActor
final class CallModel: ObservableObject {
    @Published private(set) var app: String?
    @Published private(set) var started: Date?

    private static let callApps: [(prefix: String, name: String)] = [
        ("us.zoom", "Zoom"), ("com.apple.FaceTime", "FaceTime"), ("com.apple.TelephonyUtilities", "Phone"),
        ("com.microsoft.teams", "Teams"), ("com.hnc.Discord", "Discord"), ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.skype", "Skype"), ("com.cisco.webex", "Webex"), ("com.webex", "Webex"), ("net.whatsapp", "WhatsApp"),
        ("desktop.WhatsApp", "WhatsApp"), ("ru.keepcoder.Telegram", "Telegram"), ("com.tdesktop.Telegram", "Telegram"),
        ("org.whispersystems.signal-desktop", "Signal"), ("com.google.meet", "Google Meet"),
    ]

    func update(micBundleIDs: [String]) {
        guard AppState.shared.settings.callIsland else {
            if app != nil { app = nil }
            if started != nil { started = nil }
            return
        }
        let match = micBundleIDs.lazy.compactMap { id in Self.callApps.first { id.hasPrefix($0.prefix) }?.name }.first
        if let match, app == nil {
            started = Date()
        } else if match == nil, let name = app, let started {
            AppState.shared.hud.show(icon: "phone.down.fill", text: "\(name) call ended · \(Self.duration(since: started))", seconds: 3)
            self.started = nil
        }
        if app != match { app = match }
    }

    static func duration(since date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Coding agents (Claude Code / Codex hooks via the local API)

@MainActor
final class AgentModel: ObservableObject {
    enum State: String { case working, waiting, done }

    struct Agent: Identifiable, Equatable {
        var id: String { name }
        let name: String
        var state: State
        var message: String
        var since: Date
    }

    @Published private(set) var agents: [Agent] = []

    enum Decision: String { case allow, deny, ask }

    struct Approval: Identifiable {
        let id = UUID()
        let agent: String
        let tool: String
        let detail: String
        let respond: (Decision) -> Void
    }

    /// Permission requests from agent hooks, answered from the island.
    @Published private(set) var approvals: [Approval] = []
    var pendingApproval: Approval? { approvals.first }

    /// Returns the pending approval's id, or nil when it was answered immediately.
    @discardableResult
    func requestApproval(agent: String, tool: String, detail: String, respond: @escaping (Decision) -> Void) -> UUID? {
        guard Pref.agentApprovals.bool else { respond(.ask); return nil }
        if alwaysAllow.contains("\(agent)|\(tool)") { respond(.allow); return nil }
        let approval = Approval(agent: agent, tool: tool, detail: detail, respond: respond)
        approvals.append(approval)
        NSSound(named: "Ping")?.play()
        // Fall back to the agent's own prompt if nobody answers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 110) { [weak self] in
            MainActor.assumeIsolated { self?.decide(approval.id, .ask) }
        }
        return approval.id
    }

    /// "Always allow" rules, revocable in Settings → Developer.
    @Published var alwaysAllow: [String] = UserDefaults.standard.stringArray(forKey: "alwaysAllow") ?? [] {
        didSet { UserDefaults.standard.set(alwaysAllow, forKey: "alwaysAllow") }
    }

    func allowAlways(_ id: UUID) {
        guard let a = approvals.first(where: { $0.id == id }) else { return }
        let rule = "\(a.agent)|\(a.tool)"
        if !alwaysAllow.contains(rule) { alwaysAllow.append(rule) }
        decide(id, .allow)
    }

    func decide(_ id: UUID, _ decision: Decision) {
        guard let i = approvals.firstIndex(where: { $0.id == id }) else { return }
        approvals.remove(at: i).respond(decision)
    }

    static let claudeApprovalHook = """
    {
      "hooks": {
        "PermissionRequest": [{ "hooks": [{ "type": "command", "timeout": 120,
          "command": "curl -s -m 115 --data-binary @- 'http://127.0.0.1:47219/approve?agent=Claude' || true" }] }]
      }
    }
    """

    /// Waiting for the user beats working.
    var active: Agent? { agents.first { $0.state == .waiting } ?? agents.first { $0.state == .working } }

    func update(name: String, state: State, message: String) {
        let existing = agents.firstIndex { $0.name == name }
        switch state {
        case .done:
            let since = existing.map { agents[$0].since }
            agents.removeAll { $0.name == name }
            let took = since.map { " · \(CallModel.duration(since: $0))" } ?? ""
            NSSound(named: "Glass")?.play()
            AppState.shared.hud.show(icon: "checkmark.seal.fill", text: "\(name) finished\(took)", seconds: 4)
        case .working, .waiting:
            if state == .waiting { NSSound(named: "Ping")?.play() }
            if let i = existing {
                agents[i].state = state
                agents[i].message = message
            } else {
                agents.append(Agent(name: name, state: state, message: message, since: Date()))
            }
        }
    }

    /// Drop agents that never reported back (e.g. the session was killed).
    func tick() {
        let stale = { (a: Agent) in Date().timeIntervalSince(a.since) > 3 * 3600 }
        if agents.contains(where: stale) { agents.removeAll(where: stale) }
    }

    static let claudeHooks = """
    {
      "hooks": {
        "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "curl -s -m 1 'http://127.0.0.1:47219/agent?agent=Claude&state=working' >/dev/null || true" }] }],
        "Notification": [{ "hooks": [{ "type": "command", "command": "curl -s -m 1 'http://127.0.0.1:47219/agent?agent=Claude&state=waiting' >/dev/null || true" }] }],
        "Stop": [{ "hooks": [{ "type": "command", "command": "curl -s -m 1 'http://127.0.0.1:47219/agent?agent=Claude&state=done' >/dev/null || true" }] }]
      }
    }
    """

    static let codexNotify = """
    notify = ["sh", "-c", "curl -s -m 1 'http://127.0.0.1:47219/agent?agent=Codex&state=done' >/dev/null", "_"]
    """
}

// MARK: - Face presence (lock when you walk away, wake when you return)

@MainActor
final class PresenceModel: NSObject, ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var faceVisible = false
    @Published private(set) var error: String?

    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "islet.presence")
    private nonisolated(unsafe) var lastAnalysis = Date.distantPast
    private var lastFace = Date()
    private var lockedByUs = false

    func setEnabled(_ on: Bool) {
        on ? start() : stop()
    }

    private func start() {
        guard session == nil else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                guard granted else { self.error = "Camera access denied"; return }
                // Turned off (or started twice) while the permission prompt was up.
                guard AppState.shared.settings.presenceLock, self.session == nil else { return }
                self.configure()
            }
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            error = "No camera found"
            return
        }
        let s = AVCaptureSession()
        s.sessionPreset = .low
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddInput(input), s.canAddOutput(output) else { error = "Camera unavailable"; return }
        s.addInput(input)
        s.addOutput(output)
        session = s
        lastFace = Date()
        error = nil
        running = true
        queue.async { s.startRunning() }
    }

    private func stop() {
        let s = session
        session = nil
        running = false
        faceVisible = false
        queue.async { s?.stopRunning() }
    }

    /// Called once a second.
    func tick() {
        guard running else { return }
        let timeout = Double(AppState.shared.settings.presenceTimeout)
        if !lockedByUs, Date().timeIntervalSince(lastFace) > timeout {
            lockedByUs = true
            // Sleeping the display locks the Mac when "Require password immediately" is on.
            DispatchQueue.global().async { FileTools.run("/usr/bin/pmset", ["displaysleepnow"]) }
        }
    }

    fileprivate func sawFace(_ found: Bool) {
        if faceVisible != found { faceVisible = found }
        guard found else { return }
        lastFace = Date()
        if lockedByUs {
            lockedByUs = false
            // Wake the display so the unlock prompt (Touch ID / Apple Watch / password) is ready.
            DispatchQueue.global().async { FileTools.run("/usr/bin/caffeinate", ["-u", "-t", "2"]) }
        }
    }
}

extension PresenceModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(lastAnalysis) > 1, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = Date()
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixels).perform([request])
        let found = !(request.results ?? []).isEmpty
        Task { @MainActor in self.sawFace(found) }
    }
}
