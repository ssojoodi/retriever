import AppKit
import RetrieverCore
import SwiftTerm

@main
@MainActor
struct TerminalChecks {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let settings = try ConnectionSettings(host: "127.0.0.1", username: CommandLine.arguments[3], port: CommandLine.arguments[2])
        let options = ["-F", "/dev/null", "-i", root.appendingPathComponent("client_key").path,
                       "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                       "-o", "GlobalKnownHostsFile=/dev/null", "-o", "UserKnownHostsFile=\(root.appendingPathComponent("known_hosts").path)"]
        let folder = root.appendingPathComponent("files/SSH café ' $(literal)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let request = try SSHLaunchRequest(settings: settings, path: Data(folder.path.utf8), isDirectory: true)
        let controller = SSHTerminalViewController(sshOptions: options)
        let browser = MainWindowController(sshTerminal: controller)
        let host = browser.window!
        browser.showWindow(nil)
        host.makeKeyAndOrderFront(nil)
        controller.open(request)
        browser.showTerminalPane(true)
        precondition(controller.terminal?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        app.activate(ignoringOtherApps: true)
        let view = controller.terminal!
        func output() -> String {
            let terminal = view.getTerminal()
            return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true, characterProvider: { terminal.getCharacter(for: $0) }) }.joined(separator: "")
        }
        view.send(txt: "printf '\\nREADY_FOLDER='; /bin/pwd; printf 'READY_END\\n'\n")
        wait("SSH working directory") { output().contains("READY_FOLDER=" + folder.path) }
        precondition(controller.active && controller.window!.firstResponder === view)
        let pid = view.process.shellPid
        browser.showTerminalPane(false)
        precondition(controller.active && controller.view.isHidden)
        browser.showTerminalPane(true)
        precondition(controller.active && !controller.view.isHidden && view.process.shellPid == pid)
        precondition(host.firstResponder === view)
        precondition(view.nativeBackgroundColor.usingColorSpace(.genericGray)!.whiteComponent < 0.15)
        precondition(controller.clipboardRead(source: view) == nil)
        controller.window!.setContentSize(NSSize(width: 720, height: 440))
        pump()
        view.send(txt: "stty size; printf 'RESIZE_OK\\n'\n")
        wait("Terminal resize") { output().contains("RESIZE_OK") }
        view.send(txt: "sleep 30\n")
        pump()
        view.send([3])
        view.send(txt: "printf 'INTERRUPTED_OK\\n'\n")
        wait("Ctrl-C") { output().contains("INTERRUPTED_OK") }
        let oldPID = view.process.shellPid
        let decline = choose("Keep Session")
        controller.open(request)
        decline.invalidate()
        precondition(controller.terminal === view && controller.active)
        let accept = choose("End Session")
        controller.open(request)
        accept.invalidate()
        precondition(controller.terminal !== view)
        precondition(kill(oldPID, 0) == -1 && errno == ESRCH, "Replaced SSH must be reaped")
        let next = controller.terminal!
        next.send(txt: "printf 'SSH connected\\n'; pwd\n")
        wait("Replacement session") { next.getTerminal().getLine(row: 2) != nil && controller.active }
        for _ in 0..<10 { pump() }
        let closeButton = descendants(host.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Close Terminal" }!
        precondition(controller.active && closeButton.isHidden, "An active shell must not show Close Terminal")
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-l", String(controller.window!.windowNumber), "artifacts/verification/ssh-terminal.png"]
        try shot.run(); shot.waitUntilExit()
        precondition(shot.terminationStatus == 0)
        let currentPID = next.process.shellPid
        browser.showTerminalPane(false)
        let keepOpen = choose("Keep Session")
        precondition(!browser.requestClose(afterCancellation: {}))
        keepOpen.invalidate()
        precondition(controller.active && next.window === host)
        let close = choose("End Session")
        precondition(browser.requestClose(afterCancellation: {}))
        close.invalidate()
        controller.closeSession()
        precondition(!controller.active && kill(currentPID, 0) == -1 && errno == ESRCH)
        // A failed cd must terminate SSH, not leave an interactive shell at home.
        controller.open(try SSHLaunchRequest(settings: settings, path: Data(folder.appendingPathComponent("missing").path.utf8), isDirectory: true))
        wait("Missing folder exits") { !controller.active }
        pump()
        precondition(controller.terminal != nil, "Failed startup retains diagnostics")
        controller.closeSession()

        // Normal shell exits close the embedded pane after SwiftTerm cleanup.
        for code in [0, 7] {
            controller.open(request)
            browser.showTerminalPane(true)
            let exiting = controller.terminal!
            exiting.send(txt: "exit \(code)\n")
            wait("Normal exit closes pane") { controller.terminal == nil }
            precondition(controller.view.isHidden)
        }
        controller.open(request)
        browser.showTerminalPane(true)
        controller.terminal!.send(txt: "exit 255\n")
        wait("Exit255 ends process") { !controller.active }
        pump()
        precondition(controller.terminal != nil && !controller.view.isHidden, "Exit255 retains diagnostic pane")
        controller.closeSession()

        // Real shell hooks, both sync directions, and conservative input gating.
        let integrated = try SSHLaunchRequest(settings: settings, path: Data(folder.path.utf8), isDirectory: true, syncEnabled: true)
        var reported: Data?
        var syncStatus: String? = "waiting"
        let originalStatusCallback = controller.onSyncStatus
        controller.onSyncStatus = { message in
            syncStatus = message
            FileHandle.standardError.write(Data(("SYNC: " + (message ?? "ready") + "\n").utf8))
            originalStatusCallback?(message)
        }
        controller.onDirectoryChange = { path, _ in reported = path }
        controller.open(integrated)
        browser.showTerminalPane(true)
        let shell = controller.terminal!
        let originalPath = Data(folder.resolvingSymlinksInPath().path.utf8)
        let parentPath = Data(root.appendingPathComponent("files").resolvingSymlinksInPath().path.utf8)
        wait("Shell integration startup") { reported == originalPath }
        wait("Untouched initial prompt") { syncStatus == nil }
        controller.synchronizeDirectory(parentPath, settings: settings)
        wait("Browser folder reaches shell") { controller.currentDirectory == parentPath }
        func type(_ text: String) { controller.send(source: shell, data: Array(text.utf8)[...]) }
        type("builtin cd -- " + SSHLaunchRequest.quoteForCheck(folder.path))
        type("\r")
        wait("Shell folder reports back") { reported == originalPath && controller.currentDirectory == originalPath }
        // A partial line must remain untouched until the user submits it.
        type("printf 'PRESERVED_INPUT\\n'")
        controller.synchronizeDirectory(parentPath, settings: settings)
        for _ in 0..<3 { pump() }
        precondition(controller.currentDirectory == originalPath)
        type("\r")
        wait("Deferred folder applies after submitted command") { controller.currentDirectory == parentPath }
        let other = try ConnectionSettings(host: settings.host, username: settings.username, port: "1")
        controller.setBrowserConnection(other)
        controller.synchronizeDirectory(originalPath, settings: other)
        for _ in 0..<3 { pump() }
        precondition(controller.currentDirectory == parentPath, "Cross-connection sync is blocked")
        controller.setSyncEnabled(false)
        controller.setBrowserConnection(settings)
        controller.synchronizeDirectory(originalPath, settings: settings)
        for _ in 0..<3 { pump() }
        precondition(controller.currentDirectory == parentPath, "Disabled sync does not send cd")
        type("exit")
        type("\r")
        wait("Integrated session exits") { controller.terminal == nil }
        browser.showTerminalPane(false)
        let settingsSuite = "RetrieverTerminalSettingsChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: settingsSuite)!
        defer { defaults.removePersistentDomain(forName: settingsSuite) }
        let preferences = SettingsWindowController(defaults: defaults)
        preferences.showWindow(nil)
        preferences.window!.makeKeyAndOrderFront(nil)
        @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let checkbox = descendants(preferences.window!.contentView!).compactMap { $0 as? NSButton }.first!
        precondition(checkbox.state == .off && !defaults.bool(forKey: SettingsWindowController.syncDefaultsKey))
        checkbox.performClick(nil)
        precondition(defaults.bool(forKey: SettingsWindowController.syncDefaultsKey))
        let reloaded = SettingsWindowController(defaults: defaults)
        precondition(descendants(reloaded.window!.contentView!).compactMap { $0 as? NSButton }.first!.state == .on)
        pump()
        let settingsShot = Process()
        settingsShot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        settingsShot.arguments = ["-x", "-l", String(preferences.window!.windowNumber), "artifacts/verification/ssh-folder-sync-settings.png"]
        try settingsShot.run(); settingsShot.waitUntilExit()
        precondition(settingsShot.terminationStatus == 0)
        preferences.close()
        host.close()
        print("PASS: PTY SSH, embedded focus/appearance, resize/Ctrl-C, lifecycle exit0/7/255, diagnostics, shell hooks, bidirectional folders, partial input and cross-host sync guards")
    }
    static func pump() {
        let deadline = Date().addingTimeInterval(0.1)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
    static func wait(_ reason: String, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { pump() }
        if !condition() {
            @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            for window in NSApp.windows {
                guard let content = window.contentView else { continue }
                for view in descendants(content).compactMap({ $0 as? TerminalView }) {
                    let terminal = view.getTerminal()
                    let text = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true, characterProvider: { terminal.getCharacter(for: $0) }) }.joined(separator: "\n")
                    FileHandle.standardError.write(Data((text + "\n").utf8))
                }
            }
        }
        precondition(condition(), "Timed out: \(reason)")
    }
    static func choose(_ title: String) -> Timer {
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            let clicked = MainActor.assumeIsolated {
                @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                guard let content = NSApp.modalWindow?.contentView,
                      let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { return false }
                button.performClick(nil); return true
            }
            if clicked { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        return timer
    }
}

private extension SSHLaunchRequest {
    static func quoteForCheck(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
