import AppKit

let app = NSApplication.shared
let delegate = FocusBreakApp()
app.delegate = delegate
app.setActivationPolicy(.regular)
delegate.bootstrap()
app.activate(ignoringOtherApps: true)
app.run()
