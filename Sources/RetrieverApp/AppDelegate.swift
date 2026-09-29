import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MainWindowController()
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.confirmTermination() == false ? .terminateCancel : .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
