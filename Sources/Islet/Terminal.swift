import AppKit
import SwiftTerm
import SwiftUI

/// A real PTY terminal (SwiftTerm) that keeps its shell alive across tab switches.
@MainActor
final class TerminalHost: NSObject, LocalProcessTerminalViewDelegate {
    private var terminal: LocalProcessTerminalView?

    var view: LocalProcessTerminalView {
        if let terminal { return terminal }
        let t = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 170))
        t.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        t.nativeBackgroundColor = NSColor(white: 0.07, alpha: 1)
        t.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        t.processDelegate = self
        terminal = t
        launch(t)
        return t
    }

    private func launch(_ t: LocalProcessTerminalView) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        FileManager.default.changeCurrentDirectoryPath(FileManager.default.homeDirectoryForCurrentUser.path)
        t.startProcess(executable: shell, args: ["-l"],
                       environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
                       execName: "-" + (shell as NSString).lastPathComponent)
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            guard let t = self.terminal else { return }
            t.feed(text: "\r\n[shell exited — starting a new one]\r\n")
            self.launch(t)
        }
    }
}

struct TerminalTab: View {
    var body: some View {
        TerminalRepresentable()
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.07)))
    }
}

private struct TerminalRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = AppState.shared.terminal.view
        view.removeFromSuperview()
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
