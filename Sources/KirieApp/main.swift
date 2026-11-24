import AppKit

// Kirie uses an AppKit-managed main window that hosts SwiftUI. That keeps window behaviour
// predictable however the app is started: from the Dock, by opening a .kirie project in Finder,
// or from the command line.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    // The application does not retain its delegate, so keep it alive for the life of the process.
    AppDelegate.retained = delegate
    NSApplication.shared.run()
}
