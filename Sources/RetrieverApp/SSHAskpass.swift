import AppKit
import Darwin

@MainActor
enum SSHAskpass {
    static func makePrompt(_ prompt: String, hint: String?) -> (NSAlert, NSSecureTextField?, Bool) {
        let trust = prompt.contains("Are you sure you want to continue connecting")
        let confirmation = trust || hint == "confirm"
        let alert = NSAlert()
        alert.messageText = trust ? "Trust this server?" : (confirmation ? "SSH Confirmation" : "Authenticate Connection")
        alert.informativeText = prompt
        if confirmation {
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: trust ? "Trust and Connect" : "Allow")
            return (alert, nil, true)
        }
        if hint == "none" {
            alert.messageText = "SSH Authentication"
            alert.addButton(withTitle: "OK")
            return (alert, nil, false)
        }
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.setAccessibilityLabel("Password or key passphrase")
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return (alert, field, false)
    }

    static func run() -> Never {
        let parent = getppid()
        guard parent > 1, CommandLine.arguments.count == 2 else { exit(1) }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        // The helper must not outlive an SSH connection cancelled by the main app.
        let watcher = Timer(timeInterval: 0.2, repeats: true) { _ in
            if getppid() != parent { exit(1) }
        }
        RunLoop.main.add(watcher, forMode: .common)
        RunLoop.main.add(watcher, forMode: .modalPanel)
        let hint = ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"]
        let (alert, field, confirmation) = makePrompt(CommandLine.arguments[1], hint: hint)
        application.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        watcher.invalidate()
        if confirmation {
            guard response == .alertSecondButtonReturn else { exit(1) }
            FileHandle.standardOutput.write(Data("yes\n".utf8))
        } else {
            guard response == .alertFirstButtonReturn else { exit(1) }
            if let field { FileHandle.standardOutput.write(Data((field.stringValue + "\n").utf8)) }
        }
        exit(0)
    }
}
