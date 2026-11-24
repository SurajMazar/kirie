import AppKit
import Foundation
import ProjectDomain

/// Developer tool: `Kirie <project.kirie> --capture <folder>` walks through the workspaces, saves a
/// PNG of the window for each, and quits. It renders the window's own views, so it needs no Screen
/// Recording permission. The live video layer is drawn by the GPU and appears black in these images.
@MainActor
enum UICapture {
    static var folder: URL? {
        guard let index = CommandLine.arguments.firstIndex(of: "--capture"), index + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }

    /// With `--capture-screen`, uses the system screenshot tool instead, which also captures the live
    /// video preview (the host needs Screen Recording permission).
    static var useScreen: Bool { CommandLine.arguments.contains("--capture-screen") }

    static func screenshot(window: NSWindow, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    static func snapshot(_ name: String, to folder: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let content = window.contentView else { return }
        if useScreen {
            screenshot(window: window.attachedSheet ?? window, to: folder.appendingPathComponent("\(name).png"))
            return
        }
        let view = content.superview ?? content
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("\(name).png"))
    }

    static func run(app: AppModel, folder: URL) {
        Task { @MainActor in
            func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await pause(1.0)
            if let window = NSApp.windows.first(where: { $0.isVisible }) {
                window.setFrame(NSRect(x: 60, y: 60, width: 1440, height: 900), display: true)
            }
            await pause(0.8)
            // Capture mode pins the look so documentation screenshots are consistent.
            if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
            var steps: [(String, () -> Void)] = [("01-home", { app.go(.home) })]
            if let editor = app.editor {
                steps += [
                    ("02-editor", {
                        app.go(.editor)
                        editor.player.seek(to: .init(seconds: 2.2))
                        if let clip = editor.sequence.mainTrack?.clips.dropFirst().first { editor.selection = [clip.id] }
                    }),
                    ("03-editor-text", {
                        if let text = editor.sequence.tracks.first(where: { $0.kind == .text })?.clips.first {
                            editor.selection = [text.id]
                            editor.player.seek(to: text.start + .init(seconds: 0.5))
                        }
                    }),
                    ("04-comic-panels", { UserDefaults.standard.set("panels", forKey: "comic.section"); app.go(.comic) }),
                    ("05-comic-qa", { UserDefaults.standard.set("qa", forKey: "comic.section") }),
                    ("06-comic-lyrics", { UserDefaults.standard.set("lyrics", forKey: "comic.section") }),
                    ("07-comic-reel", { UserDefaults.standard.set("reel", forKey: "comic.section") }),
                    ("08-library", { app.go(.library); editor.selectedAssetID = editor.project.assets.first { $0.kind == .image }?.id }),
                    ("09-export", { app.go(.editor); editor.showExport = true }),
                ]
            }
            steps += [("10-settings", { app.editor?.showExport = false; app.go(.settings) }), ("11-projects", { app.go(.projects) })]
            for (name, action) in steps {
                action()
                await pause(name == "09-export" ? 2.2 : 1.4)
                // Sheets are separate windows: capture the sheet when one is up.
                if !useScreen, let sheet = NSApp.windows.first(where: { $0.isVisible })?.attachedSheet, let content = sheet.contentView,
                   let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
                } else {
                    snapshot(name, to: folder)
                }
            }
            app.closeProject()
            NSApp.terminate(nil)
        }
    }
}
