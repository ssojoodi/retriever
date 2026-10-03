import AppKit
import RetrieverCore
@preconcurrency import SwiftTerm

@MainActor
private final class SSHView: LocalProcessTerminalView {
    func configureDarkColors() {
        nativeBackgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        nativeForegroundColor = NSColor(calibratedWhite: 0.90, alpha: 1)
        caretColor = NSColor(calibratedWhite: 0.90, alpha: 1)
        caretTextColor = NSColor(calibratedWhite: 0.08, alpha: 1)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        configureDarkColors()
    }
}

/// One ad-hoc session. SwiftTerm owns terminal emulation, PTY I/O and resizing.
@MainActor
final class SSHTerminalViewController: NSViewController,
    @preconcurrency LocalProcessTerminalViewDelegate, @preconcurrency TerminalViewDelegate {
    private(set) var terminal: LocalProcessTerminalView?
    var active: Bool { terminal?.process.running == true }

    private let sshOptions: [String]
    // Integration checks supply isolated identity/known-host options.
    init(sshOptions: [String] = []) {
        self.sshOptions = sshOptions
        super.init(nibName: nil, bundle: nil)
    }
    override func loadView() { view = NSView() }
    var window: NSWindow? { view.window }
    private(set) var sessionTitle = ""
    required init?(coder: NSCoder) { fatalError("Programmatic window") }

    @discardableResult
    func open(_ request: SSHLaunchRequest) -> Bool {
        guard confirmEndingSession("End the current SSH session and open another?") else { return false }
        stop()
        terminal?.removeFromSuperview()
        let view = SSHView(frame: self.view.bounds)
        view.appearance = NSAppearance(named: .darkAqua)
        view.configureDarkColors()
        view.optionAsMetaKey = false
        view.autoresizingMask = [.width, .height]
        view.processDelegate = self
        // Proxy the process callbacks, while denying remote clipboard requests.
        view.terminalDelegate = self
        view.setAccessibilityLabel("SSH terminal")
        terminal = view
        self.view.addSubview(view)
        sessionTitle = request.title
        window?.makeFirstResponder(view)
        view.startProcess(executable: "/usr/bin/ssh", args: sshOptions + request.arguments,
                          environment: SSHLaunchRequest.environment(ProcessInfo.processInfo.environment))
        if !view.process.running { view.feed(text: "Unable to start SSH.\r\n") }
        return true
    }

    func confirmEndingSession(_ message: String = "End the active SSH session?") -> Bool {
        guard active else { return true }
        window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "The SSH connection will close. Remote commands may be interrupted."
        alert.addButton(withTitle: "Keep Session")
        alert.addButton(withTitle: "End Session")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func stop() {
        terminal?.processDelegate = nil
        guard let view = terminal, view.process.running else { return }
        let pid = view.process.shellPid
        view.terminate()
        // SwiftTerm cancels its exit monitor on explicit termination. Reap our
        // child here; a bounded grace period prevents a stuck SSH from surviving.
        guard pid > 0 else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        var status: Int32 = 0
        while waitpid(pid, &status, WNOHANG) == 0 {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                break
            }
            usleep(10_000)
        }
    }
    func closeSession() {
        stop()
        terminal?.removeFromSuperview()
        terminal = nil
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === terminal else { return }
        source.feed(text: "\r\n[SSH session ended]\r\n")

    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        terminal?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { terminal?.send(source: source, data: data) }
    func scrolled(source: TerminalView, position: Double) { terminal?.scrolled(source: source, position: position) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func clipboardCopy(source: TerminalView, content: Data) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}
