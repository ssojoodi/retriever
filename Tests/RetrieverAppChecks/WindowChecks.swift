import AppKit
@testable import RetrieverCore

@main
@MainActor
struct WindowChecks {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        AppMenu.install()
        let (trust, trustField, confirmation) = SSHAskpass.makePrompt("The server fingerprint is SHA256:test. Are you sure you want to continue connecting (yes/no/[fingerprint])?", hint: nil)
        precondition(confirmation && trustField == nil)
        precondition(trust.buttons.first?.title == "Cancel", "Trust must default to cancellation")
        precondition(trust.informativeText.contains("SHA256:test"), "Fingerprint must be visible")
        let (password, secretField, secretConfirmation) = SSHAskpass.makePrompt("Password:", hint: nil)
        precondition(!secretConfirmation && secretField != nil)
        precondition(password.accessoryView is NSSecureTextField, "Secrets must use a secure field")

        let delegate = AppDelegate()
        app.delegate = delegate
        precondition(app.sendAction(#selector(AppDelegate.showRetrieverHelp(_:)), to: nil, from: nil), "Help must route to the application delegate")
        pump()
        guard let help = app.windows.first(where: { $0.title == "Retriever Help" }) else { fatalError("Missing Help panel") }
        precondition(help.isVisible)
        delegate.showRetrieverHelp(nil)
        precondition(app.windows.filter { $0.title == "Retriever Help" }.count == 1, "Help must reuse its panel")
        let screenshot = Process()
        screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        screenshot.arguments = ["-x", "-D", "1", "artifacts/verification/help-window.png"]
        try! FileManager.default.createDirectory(atPath: "artifacts/verification", withIntermediateDirectories: true)
        try! screenshot.run()
        screenshot.waitUntilExit()
        precondition(screenshot.terminationStatus == 0)
        help.performClose(nil)
        precondition(!help.isVisible)
        app.delegate = nil
        weak var releasedController: MainWindowController?
        autoreleasepool {
            var controller: MainWindowController? = MainWindowController(history: ConnectionHistory(defaults: UserDefaults(suiteName: "WindowChecks." + UUID().uuidString)!))
            releasedController = controller
            guard let window = controller?.window else { fatalError("Missing browser window") }
            controller?.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            pump()
            precondition(window.isVisible, "Browser window must be visible")
            let items = window.toolbar!.items
            precondition(items.first(where: { $0.itemIdentifier.rawValue == "connect" })?.isEnabled == true)
            precondition(items.first(where: { $0.itemIdentifier.rawValue == "download" })?.isEnabled == false)
            precondition(items.first(where: { $0.itemIdentifier.rawValue == "cancel" })?.isEnabled == false)
            window.makeKey()
            precondition(app.sendAction(#selector(MainWindowController.openConnection(_:)), to: nil, from: nil), "Connection action must route through the active window")
            pump()
            guard let sheet = window.attachedSheet else { fatalError("Missing connection sheet") }
            precondition(sheet.firstResponder is NSTextView, "Connection sheet must focus an editable field")
            window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            pump()
            precondition(window.attachedSheet == nil, "Cancel must dismiss connection sheet")
            precondition(controller?.busy == false, "Cancel must not start a connection")
            window.setContentSize(NSSize(width: 580, height: 360))
            pump()
            precondition(window.isVisible)
            window.performClose(nil)
            pump()
            precondition(!window.isVisible, "Idle window must close")
            controller = nil
        }
        pump()
        precondition(releasedController == nil, "Closed window controller must release")
        checkBusyClose()
        print("PASS: busy-close Keep Working and deferred Cancel and Close")
        print("PASS: active-window routing, initial action states, text focus, sheet cancellation, minimum-size resize, idle close and controller release")
    }

    private static func checkBusyClose() {
        let browser = SFTPBrowser(initialPath: Data(".".utf8)) { _, signal in
            try SFTPSession(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], cancellation: signal)
        }
        var controller: MainWindowController?
        weak var released: MainWindowController?
        autoreleasepool {
            controller = MainWindowController(browser: browser, history: ConnectionHistory(defaults: UserDefaults(suiteName: "WindowChecks." + UUID().uuidString)!))
            released = controller
            let window = controller!.window!
            controller!.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            pump()
            controller!.openConnection(nil)
            pump()
            guard let sheet = window.attachedSheet else { fatalError("Missing stalled connection sheet") }
            let fields = descendants(sheet.contentView!).compactMap { $0 as? NSTextField }
            fields.first { $0.accessibilityLabel() == "Server" }!.stringValue = "stalled-fixture"
            sheet.makeFirstResponder(nil)
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            pump()
            precondition(controller!.busy, "Fixture must have an active operation")
            let keep = chooseModalButton("Keep Working")
            window.performClose(nil)
            keep.invalidate()
            precondition(controller!.busy && window.isVisible, "Keep Working must preserve operation and window")
            let cancel = chooseModalButton("Cancel and Close", capture: true)
            window.performClose(nil)
            cancel.invalidate()
            let deadline = Date().addingTimeInterval(3)
            while controller!.busy && Date() < deadline { pump() }
            precondition(!controller!.busy, "Cancellation must finish promptly")
            precondition(!window.isVisible, "Accepted close must complete after cleanup without another close")
            controller = nil
        }
        let releaseDeadline = Date().addingTimeInterval(3)
        while released != nil && Date() < releaseDeadline { autoreleasepool { pump() } }
        precondition(released == nil, "Cancelled controller must release")
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func chooseModalButton(_ title: String, capture: Bool = false) -> Timer {
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            let clicked = MainActor.assumeIsolated {
                guard let window = NSApp.modalWindow, let view = window.contentView,
                      let button = descendants(view).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { return false }
                if capture {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", "-D", "1", "artifacts/verification/busy-close.png"]
                    try! process.run()
                    process.waitUntilExit()
                    precondition(process.terminationStatus == 0)
                }
                button.performClick(nil)
                return true
            }
            if clicked { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        return timer
    }

    private static func pump() {
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
