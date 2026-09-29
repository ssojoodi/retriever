import AppKit

@main
@MainActor
struct WindowChecks {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        AppMenu.install()
        weak var releasedController: MainWindowController?
        autoreleasepool {
            var controller: MainWindowController? = MainWindowController()
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
        print("PASS: active-window routing, initial action states, text focus, sheet cancellation, minimum-size resize, idle close and controller release")
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
