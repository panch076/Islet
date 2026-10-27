import Foundation
import Security
import SwiftUI

/// "Ask AI": a small chat in the island using your own Anthropic API key (stored in the Keychain).
@MainActor
final class AskAIModel: ObservableObject {
    struct Message: Identifiable, Equatable { let id = UUID(); let role: String; var text: String; var isError = false }
    @Published private(set) var messages: [Message] = []
    @Published private(set) var busy = false
    @Published var hasKey = Keychain.read() != nil

    func setKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.isEmpty ? Keychain.delete() : Keychain.save(trimmed)
        hasKey = Keychain.read() != nil
    }

    private var token = 0

    func clear() {
        token += 1 // a reply still in flight belongs to the cleared chat
        messages = []
        busy = false
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, let key = Keychain.read() else { return }
        messages.append(Message(role: "user", text: text))
        busy = true
        let mine = token
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 120
        let body: [String: Any] = [
            "model": Pref.askAIModel.string,
            "max_tokens": 1024,
            "system": "You are a concise assistant inside a Mac menu-bar island. Keep answers short and practical.",
            // Error notes are shown to you but never sent back (the API rejects empty/odd turns).
            "messages": messages.filter { !$0.isError }.map { ["role": $0.role, "content": $0.text] },
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { data, _, error in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let joined = (json?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
            let reply = joined?.isEmpty == false ? joined : nil
            let failure = (json?["error"] as? [String: Any])?["message"] as? String ?? error?.localizedDescription
            Task { @MainActor in
                guard mine == self.token else { return }
                self.busy = false
                if let reply {
                    self.messages.append(Message(role: "assistant", text: reply))
                } else {
                    // Drop the unanswered question too, so the next request stays a valid conversation.
                    if self.messages.last?.role == "user" { self.messages[self.messages.count - 1].isError = true }
                    self.messages.append(Message(role: "assistant", text: "⚠️ \(failure ?? "No response")", isError: true))
                }
            }
        }.resume()
    }
}

enum Keychain {
    private static let service = "dev.local.islet.anthropic"

    static func save(_ value: String) {
        delete()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecValueData as String: Data(value.utf8)]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

struct AskAITab: View {
    @ObservedObject private var model = AppState.shared.askAI

    /// Replies render inline Markdown (bold, code, links); your own messages stay plain.
    static func rendered(_ m: AskAIModel.Message) -> AttributedString {
        guard m.role != "user" else { return AttributedString(m.text) }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: m.text, options: options)) ?? AttributedString(m.text)
    }
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        if !model.hasKey {
            VStack(spacing: 8) {
                Image(systemName: "key.fill").font(.system(size: 24)).foregroundStyle(.secondary)
                Text("Add your Anthropic API key in Settings → AI to ask questions here.").font(.caption).foregroundStyle(.secondary)
                Button("Open Settings") { SettingsWindowController.shared.show(.ai) }.controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.messages) { m in
                                Text(Self.rendered(m))
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(m.role == "user" ? 0.14 : 0.06)))
                                    .frame(maxWidth: .infinity, alignment: m.role == "user" ? .trailing : .leading)
                                    .id(m.id)
                            }
                            if model.messages.isEmpty {
                                VStack(spacing: 6) {
                                    Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(.secondary)
                                    Text("Ask Claude anything — answers stay short and to the point.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity).padding(.top, 36)
                            }
                            if model.busy { ProgressView().controlSize(.small) }
                        }
                    }
                    .onChange(of: model.messages) { _, m in if let last = m.last { withAnimation(Motion.standard) { proxy.scrollTo(last.id, anchor: .bottom) } } }
                }
                HStack {
                    TextField("Ask anything…", text: $input).textFieldStyle(.plain).focused($focused)
                        .onSubmit { model.send(input); input = "" }
                    if !model.messages.isEmpty {
                        Button { model.clear() } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(cardBackground)
            }
            .onAppear { focused = true }
        }
    }
}
