import AppKit

// Menu-bar-only agent: no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Retain the controller for the lifetime of the app.
let controller = StatusItemController()

app.run()
