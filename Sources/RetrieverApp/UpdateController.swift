import AppKit
import RetrieverCore

@MainActor
final class UpdateController {
    let checker: UpdateChecker
    let windowController: UpdateWindowController
    private var timer: Timer?

    init(metadata: [String: Any] = Bundle.main.infoDictionary ?? [:],
         defaults: UserDefaults = .standard,
         clock: @escaping () -> Date = Date.init,
         transport: @escaping UpdateTransport = UpdateNetwork.fetch,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        let configuration = Result { try UpdateConfiguration(metadata: metadata) }
        checker = UpdateChecker(configuration: configuration,
                                installedVersion: metadata["CFBundleShortVersionString"] as? String,
                                defaults: defaults, clock: clock, transport: transport)
        windowController = UpdateWindowController(configuration: try? configuration.get(), openURL: openURL)
        checker.present = { [weak windowController] status, manual in
            windowController?.present(status, manual: manual)
        }
    }

    func setActive(_ active: Bool) {
        checker.setActive(active)
        updateTimer()
    }

    func checkManually() { checker.checkManually() }

    func toggleAutomatic() {
        checker.automaticEnabled.toggle()
        checker.checkAutomaticallyIfDue()
        updateTimer()
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard checker.automaticEnabled, checker.isActive else { return }
        // Activation also checks the deadline, so sleep and inactive periods need no timer.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checker.checkAutomaticallyIfDue() }
        }
        timer?.tolerance = 5
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        checker.stop()
        windowController.close()
    }
}

@MainActor
final class UpdateWindowController: NSWindowController {
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let download = NSButton(title: "Download", target: nil, action: nil)
    private let notes = NSButton(title: "Release Notes", target: nil, action: nil)
    private let dismiss = NSButton(title: "Later", target: nil, action: nil)
    private let configuration: UpdateConfiguration?
    private let openURL: (URL) -> Void
    private(set) var status: UpdateStatus = .checking

    init(configuration: UpdateConfiguration?, openURL: @escaping (URL) -> Void) {
        self.configuration = configuration
        self.openURL = openURL
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 220),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Retriever Updates"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = false
        super.init(window: window)
        heading.font = .boldSystemFont(ofSize: 19)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        download.target = self; download.action = #selector(openDownload)
        notes.target = self; notes.action = #selector(openNotes)
        dismiss.target = self; dismiss.action = #selector(dismissWindow)
        dismiss.keyEquivalent = "\u{1b}"
        for button in [download, notes, dismiss] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [notes, dismiss, download])
        buttons.spacing = 10
        let titleRow = NSStackView(views: [progress, heading])
        titleRow.spacing = 10
        let stack = NSStackView(views: [titleRow, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(_ status: UpdateStatus, manual: Bool) {
        self.status = status
        download.isHidden = true
        notes.isHidden = true
        dismiss.title = "Close"
        progress.stopAnimation(nil)
        switch status {
        case .checking:
            heading.stringValue = "Checking for updates…"
            detail.stringValue = "Contacting the Retriever update server."
            progress.startAnimation(nil)
        case .current(let installed):
            heading.stringValue = "Retriever is up to date"
            detail.stringValue = "Installed version: \(installed). No newer release is available."
        case .available(let installed, let latest):
            heading.stringValue = "Retriever \(latest) is available"
            detail.stringValue = "Installed version: \(installed). Download the update, then open the DMG and drag Retriever to Applications to install it."
            download.isHidden = false
            notes.isHidden = false
            dismiss.title = "Later"
        case .failed(let message):
            heading.stringValue = "Unable to check for updates"
            detail.stringValue = message
        }
        if manual { window?.makeKeyAndOrderFront(nil) }
        else { window?.orderFront(nil) }
    }

    @objc func openDownload() { if let configuration { openURL(configuration.downloadURL) } }
    @objc func openNotes() { if let configuration { openURL(configuration.releaseNotesURL) } }
    @objc private func dismissWindow() { close() }
}
