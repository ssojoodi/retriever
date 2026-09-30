import AppKit
import Quartz
@testable import RetrieverCore

/// Capture production views with disposable sample data, without personal hosts or credentials.
@main
@MainActor
struct WebsiteScreenshots {
    static func main() throws {
        let output = URL(fileURLWithPath: "web-page/screenshots/0.2.0", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: "/tmp/Retriever-Demo-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let root = fixture.appendingPathComponent("Website")
        let assets = root.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data("Website files\n\nThe latest artwork and copy for the autumn launch.\n".utf8).write(to: root.appendingPathComponent("Read me.txt"))
        try Data("body { font-family: system-ui; background: #faf7f0; }\n".utf8).write(to: root.appendingPathComponent("styles.css"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "Brand/Retriever-AppIcon.png"), to: assets.appendingPathComponent("Retriever.png"))
        try Data("Autumn launch\n\nThe new artwork is ready for the website.\n\nFiles to publish:\n  • Retriever.png — app artwork\n  • styles.css — website styles\n\nReview the preview, then download the files you need.\n".utf8).write(to: assets.appendingPathComponent("Launch notes.txt"))
        let browser = SFTPBrowser(initialPath: Data(root.path.utf8)) { _, signal in
            try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [], cancellation: signal)
        }
        let suite = "RetrieverWebsiteScreenshots.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = ConnectionHistory(defaults: defaults)
        let settings = try ConnectionSettings(host: "files.example.com", username: "alex", port: "22")
        history.remember(settings, path: Data("/team/Website".utf8))
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .aqua)
        app.finishLaunching()
        app.applicationIconImage = NSImage(contentsOfFile: "Sources/RetrieverApp/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png")
        AppMenu.install()
        let controller = MainWindowController(browser: browser, history: history)
        let window = controller.window!
        window.setContentSize(NSSize(width: 820, height: 430))
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        controller.openConnection(nil)
        wait("connection sheet") { window.attachedSheet != nil }
        let sheet = window.attachedSheet!
        sheet.makeFirstResponder(nil)
        pump(0.5)
        try capture(sheet, to: output.appendingPathComponent("saved-hosts.png"))
        descendants(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Connect" }!.performClick(nil)
        wait("listing") { !controller.busy && window.title.contains("files.example.com") }
        let outline = descendants(window.contentView!).compactMap { $0 as? NSOutlineView }.first!
        outline.expandItem(outline.item(atRow: 0))
        wait("expanded folder") { !controller.busy && outline.numberOfRows == 5 }
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        window.makeFirstResponder(outline)
        pump(0.5)
        try capture(window, to: output.appendingPathComponent("expanded-folders.png"))
        controller.previewSelected(nil)
        wait("preview") { !controller.busy && app.windows.contains { $0.title == "Launch notes.txt" && $0.isVisible } }
        let preview = app.windows.first { $0.title == "Launch notes.txt" && $0.isVisible }!
        preview.setContentSize(NSSize(width: 640, height: 360))
        pump(2)
        try capture(preview, to: output.appendingPathComponent("quick-look.png"))
        preview.performClose(nil)
        window.makeKeyAndOrderFront(nil)
        pump(0.3)
        // Capture the menu within the browser rectangle, excluding the desktop.
        let rowRect = outline.rect(ofRow: 1)
        let location = outline.convert(NSPoint(x: 190, y: rowRect.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = outline.menu(for: event)!
        let timer = Timer(timeInterval: 0.7, repeats: false) { _ in
            MainActor.assumeIsolated {
                try! capture(window, to: output.appendingPathComponent("file-menu.png"))
                outline.menu?.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        NSMenu.popUpContextMenu(menu, with: event, for: outline)
        window.performClose(nil)
        print("Captured four production UI screenshots with sample data in \(output.path)")
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
        try screenshot(["-l", String(window.windowNumber), "-o"], to: url)
    }
    static func screenshot(_ arguments: [String], to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x"] + arguments + [url.path]
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "Screenshot failed")
    }
}
