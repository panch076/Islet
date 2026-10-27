import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sound

struct SoundTab: View {
    @ObservedObject private var audio = AppState.shared.audio
    @ObservedObject private var bluetooth = AppState.shared.bluetooth

    var body: some View {
        HStack(spacing: Layout.gap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(audio.volume) }, set: { audio.setVolume(Float($0)) }), in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                Text("Output").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(audio.outputs) { device in
                            Button { audio.setOutput(device) } label: {
                                HStack {
                                    let selected = AppState.shared.eq.enabled ? device.id == AppState.shared.eq.selectedOutput : device.id == audio.currentOutput
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected ? .green : .secondary)
                                    Text(device.name).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .font(.system(size: 12))
            .padding(Layout.card).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(cardBackground)

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { audio.micMuted }, set: { _ in audio.toggleMic() })) {
                    Label("Mute microphone", systemImage: "mic.slash")
                }
                .toggleStyle(.switch).controlSize(.small)
                HStack(spacing: 10) {
                    Label("Camera", systemImage: "video.fill").foregroundStyle(audio.cameraInUse ? .green : .secondary)
                    Label("Mic", systemImage: "mic.fill").foregroundStyle(audio.micInUse ? .orange : .secondary)
                }
                .font(.caption)
                Divider()
                ForEach(bluetooth.peripherals) { d in
                    HStack {
                        Label(d.name, systemImage: d.name.localizedCaseInsensitiveContains("mouse") ? "magicmouse.fill" : d.name.localizedCaseInsensitiveContains("trackpad") ? "rectangle.and.hand.point.up.left.fill" : "keyboard.fill")
                            .font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Text("\(d.percent)%").font(.system(size: 11)).monospacedDigit().foregroundStyle(d.percent < 20 ? .red : .primary)
                    }
                }
                if bluetooth.devices.isEmpty && bluetooth.peripherals.isEmpty {
                    Text("No Bluetooth devices reporting battery").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(bluetooth.devices) { d in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(d.name, systemImage: d.isAudio ? "airpodspro" : "dot.radiowaves.left.and.right")
                            .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        HStack(spacing: 10) {
                            if let v = d.left { battery("L", v) }
                            if let v = d.right { battery("R", v) }
                            if let v = d.caseLevel { battery("Case", v) }
                            if let v = d.main { battery("", v) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(Layout.card).frame(width: 200).frame(maxHeight: .infinity, alignment: .topLeading)
            .background(cardBackground)
            EQCard()
        }
    }

    private func battery(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            if !label.isEmpty { Text(label).foregroundStyle(.secondary) }
            Text("\(value)%").foregroundStyle(value < 20 ? .red : .primary)
        }
        .font(.system(size: 11)).monospacedDigit()
    }
}

// MARK: - AI usage

struct AIUsageTab: View {
    enum Source: String, CaseIterable {
        case claude = "Claude Code", codex = "Codex", copilot = "Copilot", cursor = "Cursor"
        var visible: Bool {
            switch self {
            case .claude: return Pref.aiShowClaude.bool
            case .codex: return Pref.aiShowCodex.bool
            case .copilot: return Pref.aiShowCopilot.bool
            case .cursor: return Pref.aiShowCursor.bool
            }
        }
    }
    @ObservedObject private var usage = AppState.shared.aiUsage
    @State private var source: Source = .claude
    // Observed so the picker updates as soon as providers are shown or hidden in Settings.
    @AppStorage(Pref.aiShowClaude.rawValue) private var showClaude = true
    @AppStorage(Pref.aiShowCodex.rawValue) private var showCodex = true
    @AppStorage(Pref.aiShowCopilot.rawValue) private var showCopilot = true
    @AppStorage(Pref.aiShowCursor.rawValue) private var showCursor = true

    /// Keep the selection on a visible provider.
    private func fixSelection() {
        if !source.visible, let first = Source.allCases.first(where: \.visible) { source = first }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $source) {
                    ForEach(Source.allCases.filter(\.visible), id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 360)
                Spacer()
                if let updated = usage.updated {
                    Text(updated.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Button { usage.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
            }
            Group {
                switch source {
                case .claude: tokens(usage.claude, empty: "No Claude Code activity today", block: usage.claudeBlock)
                case .codex: tokens(usage.codex, empty: "No Codex sessions today", block: nil)
                case .copilot: copilot
                case .cursor: cursor
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(cardBackground)
        }
        .font(.system(size: 12))
        .onAppear(perform: fixSelection)
        .onChange(of: [showClaude, showCodex, showCopilot, showCursor]) { _, _ in fixSelection() }
    }

    @ViewBuilder
    private func tokens(_ t: AIUsageModel.Totals?, empty: String, block: AIUsageModel.Block?) -> some View {
        if let t {
            let s = t.sum
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today").font(.caption).foregroundStyle(.secondary)
                    Text(Self.short(s.total)).font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text(t.cost.map { String(format: "≈ $%.2f", $0) } ?? "cost unknown").foregroundStyle(.green)
                    Text("\(t.messages) \(source == .codex ? "sessions" : "messages")").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    row("Input", s.input); row("Output", s.output); row("Cache read", s.cacheRead); row("Cache write", s.cacheWrite)
                    ForEach(t.byModel.sorted { $0.value.total > $1.value.total }.prefix(2), id: \.key) { model, u in
                        Text("\(model) · \(Self.short(u.total))").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(width: 190)
                if let block {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("5-hour window").font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: min(Date().timeIntervalSince(block.start) / (5 * 3600), 1)).tint(.orange)
                        Text("Resets \(block.end.formatted(date: .omitted, time: .shortened))")
                        Text("\(Self.short(block.tokens)) tokens\(block.cost.map { String(format: " · $%.2f", $0) } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            placeholder(empty)
        }
    }

    @ViewBuilder private var copilot: some View {
        if let c = usage.copilot {
            VStack(alignment: .leading, spacing: 8) {
                Text("Plan: \(c.plan.capitalized)").font(.caption).foregroundStyle(.secondary)
                ForEach(c.quotas) { q in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(q.id.capitalized)
                            Spacer()
                            Text(q.unlimited ? "Unlimited" : "\(Int(q.remaining)) of \(Int(q.entitlement)) left").monospacedDigit()
                        }
                        if !q.unlimited {
                            ProgressView(value: q.percentRemaining / 100).tint(q.percentRemaining < 20 ? .red : .green)
                        }
                    }
                }
                if let reset = c.resetDate { Text("Resets \(reset)").font(.caption).foregroundStyle(.secondary) }
            }
        } else {
            placeholder(usage.copilotStatus)
        }
    }

    @ViewBuilder private var cursor: some View {
        if let c = usage.cursor {
            VStack(alignment: .leading, spacing: 6) {
                Text("Premium requests this month").font(.caption).foregroundStyle(.secondary)
                Text(c.limit.map { "\(c.used) / \($0)" } ?? "\(c.used)").font(.system(size: 26, weight: .semibold, design: .rounded))
                if let limit = c.limit, limit > 0 {
                    ProgressView(value: min(Double(c.used) / Double(limit), 1)).tint(.purple)
                }
            }
        } else {
            placeholder(usage.cursorStatus)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ label: String, _ n: Int) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(Self.short(n)).monospacedDigit() }.font(.system(size: 11))
    }

    static func short(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }
}

// MARK: - Snippets & reminders (Notes tab sections)

struct SnippetsView: View {
    @ObservedObject private var model = AppState.shared.snippets
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        HStack(spacing: 10) {
            ScrollView {
                VStack(spacing: 2) {
                    if model.snippets.isEmpty {
                        Text("Save text you type often. Click a snippet to copy it.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 30)
                    }
                    ForEach(model.snippets) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(s.text).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button { model.remove(s) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .contentShape(Rectangle())
                        .onTapGesture { model.copy(s) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .background(cardBackground)

            VStack(spacing: 6) {
                TextField("Name", text: $title).textFieldStyle(.roundedBorder)
                TextEditor(text: $text)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                Button("Add Snippet") {
                    model.add(title: title, text: text)
                    title = ""; text = ""
                }
                .disabled(text.isEmpty)
            }
            .frame(width: 200)
        }
        .font(.system(size: 12))
    }
}

struct RemindersView: View {
    @ObservedObject private var model = AppState.shared.reminders
    @State private var newTitle = ""

    var body: some View {
        if !model.authorized {
            Button("Connect Reminders") { model.requestAccess() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                HStack {
                    Image(systemName: "plus.circle.fill").foregroundStyle(.orange)
                    TextField("New reminder", text: $newTitle)
                        .textFieldStyle(.plain)
                        .onSubmit { model.add(newTitle); newTitle = "" }
                }
                .padding(8)
                .background(cardBackground)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.items) { item in
                            HStack {
                                Button { model.complete(item) } label: { Image(systemName: "circle") }.buttonStyle(.plain)
                                Text(item.title).lineLimit(1)
                                Spacer()
                                if let due = item.due {
                                    Text(due.formatted(date: .abbreviated, time: .omitted))
                                        .font(.system(size: 10)).foregroundStyle(due < Date() ? .red : .secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 12))
        }
    }
}

// MARK: - Equalizer card (Sound tab)

struct EQCard: View {
    @ObservedObject private var eq = AppState.shared.eq

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Equalizer").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(get: { eq.enabled }, set: { eq.setEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(!eq.driverInstalled)
            }
            if eq.driverInstalled {
                band("Bass", $eq.low)
                band("Mid", $eq.mid)
                band("Treble", $eq.high)
                HStack {
                    Menu("Presets") {
                        ForEach(EQModel.presets, id: \.name) { p in Button(p.name) { eq.applyPreset(p) } }
                    }
                    .controlSize(.small)
                }
                Menu {
                    ForEach(eq.outputChoices) { d in
                        Button { eq.route(to: d.id) } label: {
                            if d.id == eq.selectedOutput { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                        }
                    }
                } label: {
                    Label(eq.realOutputName.isEmpty ? "Play through…" : eq.realOutputName, systemImage: "hifispeaker")
                        .font(.system(size: 10)).lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The EQ uses the Islet Audio driver so there's no echo.").font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Install Driver…") { eq.installDriver() }.controlSize(.small)
            }
            if let error = eq.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Layout.card).frame(width: 180).frame(maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground)
    }

    private func band(_ name: String, _ value: Binding<Float>) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.system(size: 10)).frame(width: 36, alignment: .leading)
            Slider(value: value, in: -12...12)
            Text(String(format: "%+.0f", value.wrappedValue)).font(.system(size: 10)).monospacedDigit().frame(width: 22)
        }
    }
}

// MARK: - Shelf file actions

@MainActor
enum ShelfActions {
    static func zip(_ urls: [URL]) { perform { FileTools.zip(urls) } }
    static func unzip(_ url: URL) { perform { FileTools.unzip(url) } }
    static func convert(_ url: URL, _ type: UTType) { perform { FileTools.convert(url, to: type) } }
    static func compress(_ url: URL, _ bytes: Int) { perform { FileTools.compress(url, to: bytes) } }

    /// Runs off the main thread, then puts the result on the shelf.
    private static func perform(_ work: @escaping @Sendable () -> URL?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            Task { @MainActor in
                if let result {
                    AppState.shared.shelf.add(result)
                    AppState.shared.hud.show(icon: "checkmark.circle.fill", text: "Created \(result.lastPathComponent)")
                } else {
                    AppState.shared.hud.show(icon: "exclamationmark.triangle", text: "That didn't work")
                }
            }
        }
    }
}
