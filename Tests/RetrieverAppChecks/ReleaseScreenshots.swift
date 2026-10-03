import AppKit
@testable import RetrieverCore
import SwiftTerm

/// Website captures using production controllers and a disposable SSH server.
@main
@MainActor
struct ReleaseScreenshots {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let sample = URL(fileURLWithPath: "/tmp/Retriever-Demo-\(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sample) }
        let folder = sample.appendingPathComponent("Website")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try Data("<!doctype html><title>Autumn launch</title>\n".utf8).write(to: folder.appendingPathComponent("index.html"))
        try Data("body { font-family: system-ui; }\n".utf8).write(to: folder.appendingPathComponent("styles.css"))
        let source = root.appendingPathComponent("Launch notes.txt")
        try Data("Autumn launch\n\nArtwork and copy are ready to publish.\nUploaded with Retriever.\n".utf8).write(to: source)
        let options = ["-F", "/dev/null", "-o", "Hostname=127.0.0.1", "-i", root.appendingPathComponent("client_key").path,
                       "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "GlobalKnownHostsFile=/dev/null",
                       "-o", "UserKnownHostsFile=\(root.appendingPathComponent("known_hosts").path)"]
        let browser = SFTPBrowser(initialPath: Data(folder.path.utf8)) { settings, signal in
            try SFTPSession(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: options + SFTPSession.sshArguments(settings), cancellation: signal)
        }
        let suite = "RetrieverReleaseScreenshots.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = ConnectionHistory(defaults: defaults)
        let settings = try ConnectionSettings(host: "files.example.com", username: CommandLine.arguments[3], port: CommandLine.arguments[2])
        history.remember(settings, path: Data(folder.path.utf8))
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .aqua)
        app.finishLaunching()
        AppMenu.install()
        let terminal = SSHTerminalViewController(sshOptions: options)
        let controller = MainWindowController(browser: browser, history: history, downloads: DownloadHistory(defaults: defaults), sshTerminal: terminal)
        let window = controller.window!
        window.setContentSize(NSSize(width: 980, height: 380))
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        controller.openConnection(nil)
        wait("connection sheet") { window.attachedSheet != nil }
        let sheet = window.attachedSheet!
        sheet.makeFirstResponder(nil)
        descendants(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Connect" }!.performClick(nil)
        let outline = descendants(window.contentView!).compactMap { $0 as? NSOutlineView }.first!
        wait("listing") { !controller.busy && outline.numberOfRows == 3 }
        controller.uploadFile(source)
        wait("upload") { !controller.busy && outline.numberOfRows == 4 }
        let uploaded = try Data(contentsOf: folder.appendingPathComponent("Launch notes.txt"))
        precondition(uploaded == (try? Data(contentsOf: source)))
        window.makeFirstResponder(outline)
        let output = URL(fileURLWithPath: "web-page/screenshots/0.4.0", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        pump(0.8)
        try capture(window, to: output.appendingPathComponent("upload.png"))
        controller.sshIntoFolder(nil)
        wait("SSH process") { terminal.active }
        pump(1)
        terminal.terminal!.send(txt: "exec /bin/sh\n")
        pump(0.4)
        terminal.terminal!.send(txt: "PS1='$ '; clear\n")
        pump(0.4)
        terminal.terminal!.send(txt: "ls -1\n")
        pump(0.8)
        try capture(window, to: output.appendingPathComponent("ssh-terminal.png"))
        terminal.closeSession()
        window.performClose(nil)
        print("PASS: captured upload and SSH production UI in \(output.path)")
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
    static func wait(_ reason: String, condition: () -> Bool) {
        let until = Date().addingTimeInterval(10)
        while !condition(), Date() < until { pump(0.05) }
        precondition(condition(), "Timed out: \(reason)")
    }
    static func capture(_ window: NSWindow, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try process.run(); process.waitUntilExit()
        precondition(process.terminationStatus == 0)
    }
}
