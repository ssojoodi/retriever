import AppKit
import RetrieverCore
@preconcurrency import SwiftTerm

@MainActor
private final class SSHView: LocalProcessTerminalView {
    private var handlingProcessOutput = false
    override func dataReceived(slice: ArraySlice<UInt8>) {
        // SwiftTerm parses this feed synchronously on the process' main queue.
        // Replies to terminal queries are not user edits to the shell prompt.
        handlingProcessOutput = true
        defer { handlingProcessOutput = false }
        super.dataReceived(slice: slice)
    }
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        if handlingProcessOutput { super.send(source: self, data: data) }
        else { super.send(source: source, data: data) }
    }

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

    var onSessionClosed: (() -> Void)?
    var onDirectoryChange: ((Data, ConnectionSettings) -> Void)?
    var onSyncStatus: ((String?) -> Void)?
    private(set) var sessionSettings: ConnectionSettings?
    private var browserSettings: ConnectionSettings?
    private var syncToken: String?
    private var syncEnabled = false
    private var generation = UUID()
    private var promptGate = SSHPromptGate()
    private var pendingPath: Data?
    private var awaitingPath: Data?
    private var lastShellPath: Data?
    var currentDirectory: Data? { lastShellPath }
    private var inputRevision: UInt64 = 0
    private var navigationRevision: UInt64 = 0

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
        sessionSettings = request.settings
        browserSettings = request.settings
        syncToken = request.syncToken
        syncEnabled = request.syncToken != nil
        promptGate = SSHPromptGate()
        let currentGeneration = generation
        if let token = syncToken {
            view.getTerminal().registerOscHandler(code: SSHDirectoryIntegration.osc) { [weak self] bytes in
                guard let self, self.generation == currentGeneration,
                      let report = SSHDirectoryIntegration.decode(bytes, token: token) else { return }
                self.receive(report, generation: currentGeneration)
            }
        }
        window?.makeFirstResponder(view)
        view.startProcess(executable: "/usr/bin/ssh", args: sshOptions + request.arguments,
                          environment: SSHLaunchRequest.environment(ProcessInfo.processInfo.environment))
        if !view.process.running { view.feed(text: "Unable to start SSH.\r\n") }
        onSyncStatus?(syncEnabled && view.process.running ? "Folder sync: waiting for shell prompt…" : nil)
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
        generation = UUID()
        pendingPath = nil
        awaitingPath = nil
        lastShellPath = nil
        promptGate = SSHPromptGate()
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
        sessionSettings = nil
        syncToken = nil
        onSyncStatus?(nil)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === terminal else { return }
        let currentGeneration = generation
        // SwiftTerm passes waitpid status, and finishes its own cleanup after
        // this callback. Do not remove the view or terminate from inside it.
        let ordinaryExit = exitCode.map { ($0 & 0x7f) == 0 && (($0 >> 8) & 0xff) != 255 } ?? false
        DispatchQueue.main.async { [weak self, weak source] in
            guard let self, let source, source === self.terminal, self.generation == currentGeneration else { return }
            self.pendingPath = nil
            self.awaitingPath = nil
            if ordinaryExit {
                self.closeSession()
                self.onSessionClosed?()
            } else {
                source.feed(text: "\r\n[SSH connection ended unexpectedly. Choose File → End SSH Session to close this pane.]\r\n")
                self.onSyncStatus?("SSH connection ended. Diagnostic output retained.")
            }
        }
    }

    func setSyncEnabled(_ enabled: Bool) {
        syncEnabled = enabled
        pendingPath = nil
        awaitingPath = nil
        if !enabled { onSyncStatus?(nil) }
        else if syncToken == nil, terminal != nil { onSyncStatus?("Reopen SSH to enable folder sync.") }
        else if terminal != nil { onSyncStatus?("Folder sync enabled; waiting for the next shell prompt.") }
    }

    func setBrowserConnection(_ settings: ConnectionSettings?) {
        if settings != browserSettings { navigationRevision &+= 1 }
        browserSettings = settings
        if settings != sessionSettings {
            pendingPath = nil
            awaitingPath = nil
            if syncEnabled, terminal != nil { onSyncStatus?("Folder sync paused: Files and Terminal use different connections.") }
        }
    }

    func synchronizeDirectory(_ path: Data, settings: ConnectionSettings) {
        navigationRevision &+= 1
        guard syncEnabled, active, syncToken != nil else { return }
        browserSettings = settings
        guard settings == sessionSettings else {
            pendingPath = nil
            onSyncStatus?("Folder sync paused: Files and Terminal use different connections.")
            return
        }
        guard SSHDirectoryIntegration.validPath(path) else {
            onSyncStatus?("Folder sync unavailable for this path.")
            return
        }
        pendingPath = path == lastShellPath && awaitingPath == nil ? nil : path
        flushDirectoryChange()
    }

    private func receive(_ report: SSHDirectoryIntegration.Report, generation expected: UUID) {
        guard syncEnabled else { return }
        switch report {
        case .unavailable:
            syncToken = nil
            pendingPath = nil
            onSyncStatus?("Folder sync unavailable for this shell. Bash or Zsh is required.")
        case .prompt(let serial, let path):
            guard promptGate.prompt(serial: serial) else { return }
            let previous = lastShellPath
            lastShellPath = path
            if let settings = sessionSettings, let folder = String(data: path, encoding: .utf8) {
                sessionTitle = "\(settings.username)@\(settings.host) — \(folder)"
            }
            let revision = inputRevision
            let navigation = navigationRevision
            // Classify this report now, before another browser navigation can
            // replace awaitingPath. Only UI callbacks and writes are deferred.
            let acknowledgement = awaitingPath
            if acknowledgement != nil { awaitingPath = nil }
            let failedChange = acknowledgement.map { $0 != path } ?? false
            let reportChange = acknowledgement == nil && previous != path
            if failedChange || (reportChange && previous != nil) { pendingPath = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expected, self.syncEnabled, self.promptGate.lastSerial == serial else { return }
                if failedChange, self.navigationRevision == navigation {
                    self.onSyncStatus?("Folder sync paused: the shell could not open the requested folder.")
                    return
                }
                if reportChange, self.navigationRevision == navigation,
                   let settings = self.sessionSettings, settings == self.browserSettings {
                    self.onDirectoryChange?(path, settings)
                }
                if self.inputRevision == revision { self.flushDirectoryChange() }
            }
        }
    }

    private func flushDirectoryChange() {
        guard syncEnabled, active, syncToken != nil, browserSettings == sessionSettings else { return }
        guard let path = pendingPath else {
            onSyncStatus?(promptGate.ready ? nil : "Folder sync paused while typing or running a command; press Return at an empty prompt to resume.")
            return
        }
        guard awaitingPath == nil, promptGate.ready, let terminal,
              let command = SSHDirectoryIntegration.changeDirectory(path) else {
            onSyncStatus?("Folder sync waiting for an untouched shell prompt. Press Return at an empty prompt to resume.")
            return
        }
        pendingPath = nil
        awaitingPath = path
        promptGate.sentDirectoryChange()
        terminal.send(source: terminal, data: Array(command.utf8)[...])
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        terminal?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard source === terminal else { return }
        inputRevision &+= 1
        promptGate.input(data)
        terminal?.send(source: source, data: data)
    }
    func scrolled(source: TerminalView, position: Double) { terminal?.scrolled(source: source, position: position) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func clipboardCopy(source: TerminalView, content: Data) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}
