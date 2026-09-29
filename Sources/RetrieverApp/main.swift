import AppKit

if ProcessInfo.processInfo.environment["RETRIEVER_ASKPASS"] == "1" { SSHAskpass.run() }

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
AppMenu.install()
application.run()
