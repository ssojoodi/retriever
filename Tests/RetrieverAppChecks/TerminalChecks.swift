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
        let controller = SSHTerminalWindowController(sshOptions: options)
        controller.open(request)
        app.activate(ignoringOtherApps: true)
        let view = controller.terminal!
        func output() -> String {
            let terminal = view.getTerminal()
            return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true, characterProvider: { terminal.getCharacter(for: $0) }) }.joined(separator: "")
        }
        view.send(txt: "printf '\\nREADY_FOLDER='; /bin/pwd; printf 'READY_END\\n'\n")
        wait("SSH working directory") { output().contains("READY_FOLDER=" + folder.path) }
        precondition(controller.active && controller.window!.firstResponder === view)
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
        next.send(txt: "printf 'SSH prototype — connected\\n'; pwd\n")
        wait("Replacement session") { next.getTerminal().getLine(row: 2) != nil && controller.active }
        for _ in 0..<10 { pump() }
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-l", String(controller.window!.windowNumber), "artifacts/verification/ssh-terminal.png"]
        try shot.run(); shot.waitUntilExit()
        precondition(shot.terminationStatus == 0)
        let currentPID = next.process.shellPid
        let close = choose("End Session")
        controller.window!.performClose(nil)
        close.invalidate()
        precondition(!controller.active && kill(currentPID, 0) == -1 && errno == ESRCH)
        // A failed cd must terminate SSH, not leave an interactive shell at home.
        controller.open(try SSHLaunchRequest(settings: settings, path: Data(folder.appendingPathComponent("missing").path.utf8), isDirectory: true))
        wait("Missing folder exits") { !controller.active }
        controller.window!.performClose(nil)
        print("PASS: real PTY SSH, quoted folder, keyboard focus, resizing, Ctrl-C, replacement and close cleanup, failed cd")
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
