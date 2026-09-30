import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var helpPanel: NSPanel?
    private var controller: MainWindowController?
    private var bundledIcon: NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }
    @objc func showAbout(_ sender: Any?) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let icon = bundledIcon {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = bundledIcon { NSApp.applicationIconImage = icon }
        controller = MainWindowController()
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showRetrieverHelp(_ sender: Any?) {
        if let helpPanel { helpPanel.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Retriever Help"
        panel.minSize = NSSize(width: 420, height: 340)
        panel.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: panel.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .systemFont(ofSize: 14)
        text.textColor = .labelColor
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 22, height: 22)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        text.string = """
        Connect to a server
        Choose Open Connection (⌘O). Enter the server hostname, username and port; SFTP usually uses port 22. Retriever uses your SSH keys or agent, or asks for a password or key passphrase. Passwords are not saved by Retriever.

        Return to a saved host
        Open Connection remembers successful hosts and their last visited folder. Choose a saved host to reconnect, or New connection to use another server. Leave Remote folder empty to start in the server home folder. Forget removes the selected saved host; it does not remove SSH host trust. If a remembered folder is unavailable, Retriever opens the server home folder.

        Verify a new server
        Compare the displayed fingerprint with one provided by the server administrator before choosing Trust and Connect. Cancel if it does not match. Accepted keys are saved in SSH known_hosts. A changed key is rejected.

        Browse and retrieve
        Double-click a folder to open it. Use Up (⌘[) to return to the enclosing folder or Refresh (⌘R) to reload. Select a regular file and choose Download (⌘D). Choose a new local filename; existing files are preserved. Folder and symbolic-link downloads are not supported yet.

        Cancel and disconnect
        Cancel (⌘.) stops the current operation, closes the connection and removes partial downloads. Disconnect ends an idle connection. Closing or quitting during work asks whether to cancel first.

        Connection trouble
        Check the hostname, port, username and server availability. Read the SSH error details for rejected credentials or host-key problems. Authentication prompts expire after five minutes; stalled transfers time out after 30 seconds.
        """
        text.setAccessibilityLabel("Retriever instructions")
        scroll.documentView = text
        panel.contentView?.addSubview(scroll)
        helpPanel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        let canQuit = controller.requestClose { NSApp.terminate(nil) }
        return canQuit ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
