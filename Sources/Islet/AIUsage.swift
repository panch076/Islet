import Foundation

/// AI coding tool usage: Claude Code and Codex from their local logs (with cost estimates from
/// LiteLLM's public price list), GitHub Copilot quotas via the gh CLI, and Cursor's usage API.
@MainActor
final class AIUsageModel: ObservableObject {
    struct ModelUsage: Equatable {
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
        var total: Int { input + output + cacheRead + cacheWrite }

        static func += (l: inout ModelUsage, r: ModelUsage) {
            l.input += r.input; l.output += r.output; l.cacheRead += r.cacheRead; l.cacheWrite += r.cacheWrite
        }
    }

    struct Totals: Equatable {
        var byModel: [String: ModelUsage] = [:]
        var messages = 0
        var cost: Double?
        var sum: ModelUsage { byModel.values.reduce(into: ModelUsage()) { $0 += $1 } }
    }

    /// Claude's usage limits reset in 5-hour windows that start at the first message.
    struct Block: Equatable {
        let start: Date
        let end: Date
        var tokens: Int
        var cost: Double?
    }

    struct Quota: Identifiable, Equatable {
        let id: String
        let remaining: Double
        let entitlement: Double
        let unlimited: Bool
        let percentRemaining: Double
    }

    struct Copilot: Equatable {
        let plan: String
        let quotas: [Quota]
        let resetDate: String?
    }

    struct Cursor: Equatable {
        let used: Int
        let limit: Int?
        let since: String?
    }

    @Published private(set) var claude: Totals?
    @Published private(set) var claudeBlock: Block?
    @Published private(set) var codex: Totals?
    @Published private(set) var copilot: Copilot?
    @Published private(set) var copilotStatus = "Checking…"
    @Published private(set) var cursor: Cursor?
    @Published private(set) var cursorStatus = "Checking…"
    @Published private(set) var updated: Date?

    private var scanning = false
    private var alerted: Set<String> = []
    private var lastRemote = Date.distantPast

    func refresh() {
        guard !scanning else { return }
        scanning = true
        // Copilot (spawns gh) and Cursor (network) change slowly; fetch them every 5 minutes.
        let remote = Date().timeIntervalSince(lastRemote) > 300
        if remote { lastRemote = Date() }
        DispatchQueue.global(qos: .utility).async {
            let prices = Pricing.load()
            let (claude, block) = Self.scanClaude(prices)
            let codex = Self.scanCodex(prices)
            let copilotResult = remote ? Self.fetchCopilot() : nil
            let cursorResult = remote ? Self.fetchCursor() : nil
            Task { @MainActor in
                self.scanning = false
                self.claude = claude
                self.claudeBlock = block
                self.codex = codex
                if let (copilot, status) = copilotResult { self.copilot = copilot; self.copilotStatus = status }
                if let (cursor, status) = cursorResult { self.cursor = cursor; self.cursorStatus = status }
                self.updated = Date()
                self.checkAlerts()
            }
        }
    }

    private func checkAlerts() {
        let day = PomodoroModel.dayKey(Date()) // local day, not UTC
        let hud = AppState.shared.hud
        let limit = AppState.shared.settings.aiDailyTokenAlert
        let total = (claude?.sum.total ?? 0) + (codex?.sum.total ?? 0)
        if limit > 0, total >= limit * 1_000_000, alerted.insert("tokens-\(day)").inserted {
            hud.show(icon: "gauge.with.dots.needle.100percent", text: "AI usage passed \(limit)M tokens today", seconds: 5)
        }
        for q in copilot?.quotas ?? [] where !q.unlimited && q.percentRemaining < Double(Pref.copilotAlert.int) {
            if alerted.insert("copilot-\(q.id)-\(day)").inserted {
                hud.show(icon: "exclamationmark.triangle.fill", text: "Copilot \(q.id): \(Int(q.percentRemaining))% left", seconds: 5)
            }
        }
        if let b = claudeBlock, b.end.timeIntervalSinceNow < 15 * 60, b.end > Date(),
           alerted.insert("block-\(b.start.timeIntervalSince1970)").inserted {
            hud.show(icon: "clock.badge.exclamationmark", text: "Claude window resets \(b.end.formatted(date: .omitted, time: .shortened))", seconds: 4)
        }
    }

    // MARK: Claude Code

    /// Parsed usage per log file, plus how far into the file we've read. Claude Code logs only grow,
    /// so each scan reads just the newly appended lines instead of re-parsing megabytes every minute.
    private final class LogCache: @unchecked Sendable {
        struct Entry { let id: String?; let date: Date; let model: String; let usage: ModelUsage }
        struct File { var offset: UInt64 = 0; var entries: [Entry] = [] }
        var files: [String: File] = [:]
        let lock = NSLock()
    }
    nonisolated private static let claudeCache = LogCache()
    nonisolated private static let usageMarker = Data("\"usage\"".utf8)

    nonisolated private static func scanClaude(_ prices: [String: [String: Any]]) -> (Totals?, Block?) {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return (nil, nil) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let cache = claudeCache
        cache.lock.lock()
        defer { cache.lock.unlock() }

        var active = Set<String>()
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate, modified > cutoff else { continue }
            let path = url.path
            active.insert(path)
            let size = UInt64(values.fileSize ?? 0)
            var file = cache.files[path] ?? LogCache.File()
            if size < file.offset { file = LogCache.File() } // rewritten or truncated: start over
            if size > file.offset, let handle = try? FileHandle(forReadingFrom: url) {
                try? handle.seek(toOffset: file.offset)
                let data = (try? handle.readToEnd()) ?? Data()
                try? handle.close()
                // Only consume complete lines; a partial last line may still be being written.
                if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                    let chunk = data[data.startIndex..<lastNewline]
                    file.offset += UInt64(lastNewline - data.startIndex + 1)
                    for line in chunk.split(separator: UInt8(ascii: "\n")) where line.count > 20 {
                        guard line.range(of: usageMarker) != nil,
                              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                              let stamp = obj["timestamp"] as? String, let date = f.date(from: stamp), date > cutoff,
                              let msg = obj["message"] as? [String: Any],
                              let u = msg["usage"] as? [String: Any] else { continue }
                        let usage = ModelUsage(input: u["input_tokens"] as? Int ?? 0, output: u["output_tokens"] as? Int ?? 0,
                                               cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                                               cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0)
                        file.entries.append(.init(id: msg["id"] as? String, date: date, model: msg["model"] as? String ?? "unknown", usage: usage))
                    }
                }
            }
            file.entries.removeAll { $0.date <= cutoff }
            cache.files[path] = file
        }
        // Forget files that went quiet so the cache doesn't grow forever.
        cache.files = cache.files.filter { active.contains($0.key) }

        var entries: [(date: Date, model: String, usage: ModelUsage)] = []
        var seen = Set<String>()
        for file in cache.files.values {
            for entry in file.entries {
                // Streaming can log one message several times; count each id once.
                if let id = entry.id, !seen.insert(id).inserted { continue }
                entries.append((entry.date, entry.model, entry.usage))
            }
        }
        entries.sort { $0.date < $1.date }

        var today = Totals()
        var blockStart: Date?
        var last: Date?
        var blockTokens = 0
        var blockCost: Double?
        for entry in entries {
            let cost = Pricing.cost(entry.model, entry.usage, prices)
            if Calendar.current.isDateInToday(entry.date) {
                today.byModel[entry.model, default: ModelUsage()] += entry.usage
                today.messages += 1
            }
            if blockStart == nil || entry.date >= blockStart!.addingTimeInterval(5 * 3600)
                || (last.map { entry.date.timeIntervalSince($0) >= 5 * 3600 } ?? false) {
                blockStart = Calendar.current.dateInterval(of: .hour, for: entry.date)?.start ?? entry.date
                blockTokens = 0
                blockCost = nil
            }
            blockTokens += entry.usage.total
            if let cost { blockCost = (blockCost ?? 0) + cost }
            last = entry.date
        }
        today.cost = Pricing.total(today.byModel, prices)

        var block: Block?
        if let start = blockStart, Date() < start.addingTimeInterval(5 * 3600) {
            block = Block(start: start, end: start.addingTimeInterval(5 * 3600), tokens: blockTokens, cost: blockCost)
        }
        return (today.messages > 0 ? today : nil, block)
    }

    // MARK: Codex

    /// ~/.codex/sessions/YYYY/MM/DD/*.jsonl — token_count events carry a running total per session.
    nonisolated private static func scanCodex(_ prices: [String: [String: Any]]) -> Totals? {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(format: ".codex/sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!))
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        var t = Totals()
        for url in files where url.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: url) else { continue }
            var last: [String: Any]?
            var model = "codex"
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let s = String(data: line, encoding: .utf8), s.contains("token_count") || s.contains("\"model\""),
                      let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any] else { continue }
                if let m = payload["model"] as? String { model = m }
                if let info = payload["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any] {
                    last = total
                }
            }
            guard let last else { continue }
            let cached = last["cached_input_tokens"] as? Int ?? 0
            t.byModel[model, default: ModelUsage()] += ModelUsage(input: (last["input_tokens"] as? Int ?? 0) - cached,
                                                                 output: last["output_tokens"] as? Int ?? 0, cacheRead: cached)
            t.messages += 1
        }
        t.cost = Pricing.total(t.byModel, prices)
        return t.messages > 0 ? t : nil
    }

    // MARK: Copilot

    nonisolated private static func fetchCopilot() -> (Copilot?, String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let gh = ["\(home)/.local/bin/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return (nil, "Install the GitHub CLI (gh) and run gh auth login")
        }
        guard let data = run(gh, ["api", "/copilot_internal/user"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, "Couldn't reach Copilot — is gh logged in?")
        }
        let snapshots = json["quota_snapshots"] as? [String: [String: Any]] ?? [:]
        let quotas = snapshots.keys.sorted().compactMap { key -> Quota? in
            // Skip quotas the plan doesn't include (entitlement 0), e.g. premium requests on Copilot Free.
            guard let q = snapshots[key], (q["unlimited"] as? Bool ?? false) || (q["entitlement"] as? Double ?? 0) > 0 else { return nil }
            return Quota(id: key.replacingOccurrences(of: "_", with: " "),
                         remaining: q["remaining"] as? Double ?? q["quota_remaining"] as? Double ?? 0,
                         entitlement: q["entitlement"] as? Double ?? 0,
                         unlimited: q["unlimited"] as? Bool ?? false,
                         percentRemaining: q["percent_remaining"] as? Double ?? 100)
        }
        let plan = (json["access_type_sku"] as? String ?? json["copilot_plan"] as? String ?? "copilot")
            .replacingOccurrences(of: "_", with: " ")
        return (Copilot(plan: plan, quotas: quotas, resetDate: json["quota_reset_date"] as? String), "")
    }

    // MARK: Cursor

    nonisolated private static func fetchCursor() -> (Cursor?, String) {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        guard FileManager.default.fileExists(atPath: db) else { return (nil, "Cursor isn't installed") }
        guard let tokenData = run("/usr/bin/sqlite3", [db, "select value from ItemTable where key='cursorAuth/accessToken'"]),
              let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
              let userID = jwtSubject(token)?.split(separator: "|").last.map(String.init) else {
            return (nil, "Sign in to Cursor first")
        }
        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage?user=\(userID)")!)
        request.setValue("WorkosCursorSessionToken=\(userID)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 10
        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in body = data; sem.signal() }.resume()
        sem.wait()
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let premium = json["gpt-4"] as? [String: Any] else {
            return (nil, "Cursor usage unavailable")
        }
        return (Cursor(used: premium["numRequests"] as? Int ?? 0, limit: premium["maxRequestUsage"] as? Int,
                       since: json["startOfMonth"] as? String), "")
    }

    nonisolated private static func jwtSubject(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["sub"] as? String
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}

/// Per-token prices from LiteLLM's public model list, cached for a day.
enum Pricing {
    private static let source = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    /// Parsed once and kept in memory; the file is several MB of JSON.
    nonisolated(unsafe) private static var memory: (loaded: Date, table: [String: [String: Any]])?

    static func load() -> [String: [String: Any]] {
        if let memory, Date().timeIntervalSince(memory.loaded) < 6 * 3600 { return memory.table }
        let table = loadFromDisk()
        memory = (Date(), table)
        return table
    }

    private static func loadFromDisk() -> [String: [String: Any]] {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Islet")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = dir.appendingPathComponent("pricing.json")
        let age = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate.map { -$0.timeIntervalSinceNow }
        if age == nil || age! > 24 * 3600, let fresh = try? Data(contentsOf: source), parse(fresh) != nil {
            try? fresh.write(to: cache)
        }
        return (try? Data(contentsOf: cache)).flatMap(parse) ?? [:]
    }

    private static func parse(_ data: Data) -> [String: [String: Any]]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
    }

    static func cost(_ model: String, _ u: AIUsageModel.ModelUsage, _ prices: [String: [String: Any]]) -> Double? {
        let undated = model.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        guard let p = [model, "anthropic/\(model)", "openai/\(model)", undated, "anthropic/\(undated)"].lazy.compactMap({ prices[$0] }).first,
              let input = p["input_cost_per_token"] as? Double else { return nil }
        let output = p["output_cost_per_token"] as? Double ?? 0
        let read = p["cache_read_input_token_cost"] as? Double ?? input * 0.1
        let write = p["cache_creation_input_token_cost"] as? Double ?? input * 1.25
        return Double(u.input) * input + Double(u.output) * output + Double(u.cacheRead) * read + Double(u.cacheWrite) * write
    }

    static func total(_ byModel: [String: AIUsageModel.ModelUsage], _ prices: [String: [String: Any]]) -> Double? {
        let costs = byModel.compactMap { cost($0.key, $0.value, prices) }
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }
}
