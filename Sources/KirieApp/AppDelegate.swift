import AppKit
import KirieServices
import Persistence
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static var retained: AppDelegate?
    let app = AppModel()
    private var window: NSWindow?
    private var pending: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        applyAppearance()
        NSApp.mainMenu = buildMenu()

        let root = RootView().environment(app).frame(minWidth: 980, minHeight: 620)
        let hosting = NSHostingView(rootView: root)
        // Let SwiftUI's .toolbar and .navigationTitle drive the real window toolbar and title.
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = hosting
        window.title = "Kirie"
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 980, height: 620)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("KirieMainWindow")
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        launched = true
        pending.forEach { app.openProject(at: $0) }
        pending.removeAll()
        // `Kirie /path/Project.kirie` also arrives through application(_:open:); this covers hosts that pass it only as an argument.
        if app.editor == nil, let path = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".\(ProjectPackage.fileExtension)") }) {
            app.openProject(at: URL(fileURLWithPath: path))
        }
        if let folder = UICapture.folder { UICapture.run(app: app, folder: folder) }

        UserDefaults.standard.addObserver(self, forKeyPath: "appearance", options: [.new], context: nil)
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        Task { @MainActor in self.applyAppearance() }
    }

    private func applyAppearance() {
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension == ProjectPackage.fileExtension {
            if launched { app.openProject(at: url) } else { pending.append(url) }
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) { app.closeProject() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Menu

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        if let action, responds(to: action) { item.target = self }
        return item
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem()
            let submenu = NSMenu(title: title)
            items.forEach(submenu.addItem)
            holder.submenu = submenu
            main.addItem(holder)
        }
        menu("Kirie", [
            item("About Kirie", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(showSettings), ","),
            .separator(),
            item("Hide Kirie", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Kirie", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("File", [
            item("New Project…", #selector(newProject), "n"),
            item("Open Project…", #selector(openProject), "o"),
            .separator(),
            item("Import Media…", #selector(importMedia), "i"),
            item("Export…", #selector(exportVideo), "e"),
            .separator(),
            item("Save Snapshot", #selector(saveSnapshot), "s"),
            item("Close Project", #selector(closeProject), "w", [.command, .shift]),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        menu("Edit", [
            item("Undo", #selector(undoEdit), "z"),
            item("Redo", #selector(redoEdit), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        menu("Clip", [
            item("Split at Playhead", #selector(splitClip), "b"),
            item("Duplicate", #selector(duplicateClip), "d"),
            item("Select All Clips", #selector(selectAllClips), "a", [.command, .shift]),
            .separator(),
            item("Delete", #selector(deleteClip)),
            item("Ripple Delete", #selector(rippleDeleteClip)),
            .separator(),
            item("Add Marker", #selector(addMarker), "m", [.command, .shift]),
        ])
        menu("Playback", [
            item("Play / Pause", #selector(playPause)),
            item("Go to Start", #selector(goToStart), String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
            item("Go to End", #selector(goToEnd), String(UnicodeScalar(NSRightArrowFunctionKey)!)),
            .separator(),
            item("Zoom Timeline In", #selector(zoomIn), "="),
            item("Zoom Timeline Out", #selector(zoomOut), "-"),
        ])
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        let windowHolder = NSMenuItem()
        windowHolder.submenu = windowMenu
        main.addItem(windowHolder)
        NSApp.windowsMenu = windowMenu
        return main
    }

    private var typing: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let editor = app.editor
        switch menuItem.action {
        case #selector(importMedia), #selector(exportVideo), #selector(saveSnapshot), #selector(closeProject), #selector(splitClip), #selector(selectAllClips),
             #selector(addMarker), #selector(playPause), #selector(goToStart), #selector(goToEnd), #selector(zoomIn), #selector(zoomOut):
            return editor != nil
        case #selector(duplicateClip), #selector(deleteClip), #selector(rippleDeleteClip):
            return editor?.selection.isEmpty == false
        case #selector(undoEdit):
            if let typing { return typing.undoManager?.canUndo ?? false }
            menuItem.title = editor?.undoLabel.map { "Undo \($0)" } ?? "Undo"
            return editor?.canUndo == true
        case #selector(redoEdit):
            if let typing { return typing.undoManager?.canRedo ?? false }
            menuItem.title = editor?.redoLabel.map { "Redo \($0)" } ?? "Redo"
            return editor?.canRedo == true
        default:
            return true
        }
    }

    @objc private func showSettings() { app.go(.settings) }
    @objc private func newProject() { app.showNewProject = true }
    @objc private func openProject() { app.chooseProjectToOpen() }
    @objc private func importMedia() { app.editor?.chooseFilesToImport() }
    @objc private func exportVideo() { app.editor?.showExport = true }
    @objc private func saveSnapshot() { app.editor?.createSnapshot(named: "Snapshot") }
    @objc private func closeProject() { app.closeProject() }
    // While typing, undo belongs to the text field; otherwise to the project.
    @objc private func undoEdit() { if let typing { typing.undoManager?.undo() } else { app.editor?.undo() } }
    @objc private func redoEdit() { if let typing { typing.undoManager?.redo() } else { app.editor?.redo() } }
    @objc private func splitClip() { app.editor?.splitAtPlayhead() }
    @objc private func duplicateClip() { app.editor?.duplicateSelection() }
    @objc private func selectAllClips() { app.editor?.selectAll() }
    @objc private func deleteClip() { app.editor?.deleteSelection(ripple: false) }
    @objc private func rippleDeleteClip() { app.editor?.deleteSelection(ripple: true) }
    @objc private func addMarker() { app.editor?.addMarker() }
    @objc private func playPause() { app.editor?.player.togglePlay() }
    @objc private func goToStart() { app.editor?.player.seek(to: .zero) }
    @objc private func goToEnd() { if let editor = app.editor { editor.player.seek(to: editor.sequence.duration) } }
    @objc private func zoomIn() { if let editor = app.editor { editor.zoom = min(600, editor.zoom * 1.4) } }
    @objc private func zoomOut() { if let editor = app.editor { editor.zoom = max(6, editor.zoom / 1.4) } }
}
