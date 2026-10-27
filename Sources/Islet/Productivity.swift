import AppKit
import EventKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Reminders

@MainActor
final class RemindersModel: ObservableObject {
    struct Item: Identifiable {
        let id: String
        let title: String
        let due: Date?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var authorized = false
    private let store = EKEventStore()

    init() {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(macOS 14, *) { authorized = status == .fullAccess } else { authorized = status == .authorized }
        if authorized { reload() }
    }

    func requestAccess() {
        let done: EKEventStoreRequestAccessCompletionHandler = { granted, _ in
            Task { @MainActor in
                self.authorized = granted
                self.reload()
            }
        }
        if #available(macOS 14, *) {
            store.requestFullAccessToReminders(completion: done)
        } else {
            store.requestAccess(to: .reminder, completion: done)
        }
    }

    func reload() {
        guard authorized else { return }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { reminders in
            let mapped = (reminders ?? []).map {
                Item(id: $0.calendarItemIdentifier, title: $0.title ?? "", due: $0.dueDateComponents?.date)
            }
            Task { @MainActor in self.items = mapped }
        }
    }

    func add(_ title: String) {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard authorized, !title.isEmpty, let list = store.defaultCalendarForNewReminders() else { return }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = list
        do {
            try store.save(r, commit: true)
            AppState.shared.hud.show(icon: "checklist", text: "Reminder added")
            reload()
        } catch {
            AppState.shared.hud.show(icon: "exclamationmark.triangle", text: "Couldn't save reminder")
        }
    }

    func complete(_ item: Item) {
        guard let r = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        r.isCompleted = true
        try? store.save(r, commit: true)
        items.removeAll { $0.id == item.id }
    }
}

// MARK: - Snippets

@MainActor
final class SnippetsModel: ObservableObject {
    struct Snippet: Identifiable, Codable, Equatable {
        var id = UUID()
        var title: String
        var text: String
    }

    @Published var snippets: [Snippet] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(snippets), forKey: "snippets") }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "snippets"),
           let saved = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = saved
        }
    }

    func add(title: String, text: String) {
        guard !text.isEmpty else { return }
        snippets.append(Snippet(title: title.isEmpty ? String(text.prefix(30)) : title, text: text))
    }

    func copy(_ s: Snippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.text, forType: .string)
        AppState.shared.hud.show(icon: "text.badge.checkmark", text: "Snippet copied")
    }

    func remove(_ s: Snippet) { snippets.removeAll { $0.id == s.id } }
}

// MARK: - Shelf file tools

enum FileTools {
    /// Zips one or more files next to the first one. Returns the archive URL.
    static func zip(_ urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        let parent = first.deletingLastPathComponent()
        let base = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        let dest = unique(parent.appendingPathComponent(base).appendingPathExtension("zip"))
        if urls.count == 1 {
            return run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, dest.path]) ? dest : nil
        }
        // zip stores paths relative to the working directory; -j flattens items from different folders.
        let sameParent = urls.allSatisfy { $0.deletingLastPathComponent() == parent }
        let args = ["-r", "-q", dest.path] + (sameParent ? urls.map(\.lastPathComponent) : ["-j"] + urls.map(\.path))
        return run("/usr/bin/zip", args, in: parent) ? dest : nil
    }

    static func unzip(_ url: URL) -> URL? {
        let dest = unique(url.deletingPathExtension())
        return run("/usr/bin/ditto", ["-x", "-k", url.path, dest.path]) ? dest : nil
    }

    static func convert(_ url: URL, to type: UTType) -> URL? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ext = type.preferredFilenameExtension else { return nil }
        let dest = unique(url.deletingPathExtension().appendingPathExtension(ext))
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(out) ? dest : nil
    }

    static func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)??.conforms(to: .image) ?? false
    }

    static func unique(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            n += 1
        }
        return candidate
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], in dir: URL? = nil) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let dir { p.currentDirectoryURL = dir }
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

// MARK: - Screen capture

enum ScreenCapture {
    enum Mode { case selectionToClipboard, selectionToDesktop, windowToClipboard, fullScreenToDesktop }

    @MainActor
    static func capture(_ mode: Mode) {
        var args: [String]
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss" // local time, like macOS's own screenshots
        let file = desktop.appendingPathComponent("Screenshot \(stamp.string(from: Date())).png").path
        switch mode {
        case .selectionToClipboard: args = ["-i", "-c"]
        case .selectionToDesktop: args = ["-i", file]
        case .windowToClipboard: args = ["-i", "-W", "-c"]
        case .fullScreenToDesktop: args = [file]
        }
        // Let the island collapse first so it isn't in the shot.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            let ok = FileTools.run("/usr/sbin/screencapture", args)
            Task { @MainActor in
                if ok { AppState.shared.hud.show(icon: "camera.viewfinder", text: args.contains("-c") ? "Screenshot copied" : "Saved to Desktop") }
            }
        }
    }
}
