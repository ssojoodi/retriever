import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var helpPanel: NSPanel?
    private var settingsController: SettingsWindowController?
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
    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.showWindow(sender)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func showDownloads(_ sender: Any?) { controller?.showDownloads(sender) }
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
        Click a folder’s arrow to expand it inline, or double-click to open it. Use Up (⌘[) to return to the enclosing folder or Refresh (⌘R) to reload. Select files or folders with Command/Shift and choose Download (⌘D) to retrieve them sequentially. Drag selected items into Finder to download there. Right-click a file for Download or Preview, or press Space to preview the selected file. Escape closes Preview or cancels its download. Files larger than 1 MB require confirmation. Preview opens a temporary copy in Quick Look; closing it removes the copy. Choose a local filename; approve Replace in the save dialog to replace an existing file after the download completes. Folders include their contents and empty subfolders. Symbolic links are skipped.

        Upload
        Choose Upload (⌘U) to send selected local files and folders sequentially to the displayed remote folder. You can also drag them in: drop onto a folder to upload there, or elsewhere for the displayed folder. Approve Replace to replace a remote file; this requires server support for atomic replacement. Existing folders require Merge approval; file conflicts offer Replace, Skip, or Cancel. Symbolic links are skipped. Uploaded files have owner-only read/write permissions. If the connection fails, an alert identifies any temporary remote file that may remain.

        Cancel and disconnect
        Cancel (⌘.) stops the batch and removes the current partial file. Completed files and created folders remain. Recoverable errors allow the remaining items to continue; connection loss stops the batch. The connection stays open when the protocol can be safely reused. Disconnect closes both Files and SSH, with confirmation if a shell session is active. Closing or quitting during work asks whether to cancel first.

        SSH terminal
        Right-click a file or folder and choose SSH into Folder. Selecting a file opens its parent folder. Files / Terminal switches views without ending SSH. Exit the shell to return to Files; File → End SSH Session can stop a stuck session. Failed connections retain diagnostic output until Close Terminal.

        Folder sync
        Settings (⌘,) can keep Files and Terminal folders in sync for new Bash and Zsh sessions. Sync is off by default and waits while you type, run commands, or transfer files. Press Return at an empty prompt to resume paused sync.

        Download history
        Open Downloads (⇧⌘J) to see completed downloads and reveal them in Finder. Clear History removes the records, not your files. Previews are not included.

        Connection trouble
        File errors preserve the connection when possible. If the connection is lost, the listing stays visible; choose Reconnect to continue.
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
    func applicationWillTerminate(_ notification: Notification) { controller?.stopTerminal(); controller?.closePreview() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
