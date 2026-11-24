import AppKit
import Persistence
import ProjectDomain
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("projectFolder") private var projectFolder = ""
    @AppStorage("onboardingDismissed") private var onboardingDismissed = false
    @State private var usage: StorageUsage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Text("Settings").font(Theme.Font.workspaceTitle).foregroundStyle(Theme.text)

                card("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("Match system").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 280)
                    Text("Kirie follows the system settings for Reduce Motion, Increase Contrast and VoiceOver.").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                }

                card("Projects") {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Theme.secondary)
                        Text(app.projectFolder.path).font(Theme.Font.label).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { projectFolder = url.path }
                        }
                        .buttonStyle(.kirieCompact)
                        Button("Reset") { projectFolder = "" }.buttonStyle(.kirieCompact).disabled(projectFolder.isEmpty)
                    }
                    Text("New projects are created here. Kirie saves after every change; there is no Save command to remember.").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                    Button("Show getting started again") { onboardingDismissed = false }.buttonStyle(.kirieCompact).disabled(!onboardingDismissed)
                }

                if let editor = app.editor {
                    card("Storage for “\(editor.project.name)”") {
                        if let usage {
                            row("Media inside the project", usage.media)
                            row("Thumbnails and waveforms", usage.thumbnails + usage.waveforms)
                            row("Render cache and proxies", usage.cache + usage.proxies)
                            row("Snapshots", usage.snapshots)
                            row("Exports", usage.exports)
                            HStack {
                                Button("Clear regenerable caches (\(formatBytes(usage.purgeable)))") {
                                    editor.session.package.purgeCaches()
                                    editor.cache.reset()
                                    self.usage = editor.session.package.storageUsage()
                                }
                                .buttonStyle(.kirie).disabled(usage.purgeable == 0)
                                Button("Collect media into the project") {
                                    do {
                                        let report = try editor.session.collectMedia()
                                        editor.syncFromSession(reload: false)
                                        editor.notify(.success, "Collected \(report.copied) file\(report.copied == 1 ? "" : "s") (\(formatBytes(report.bytesCopied))). The project is now portable.")
                                        self.usage = editor.session.package.storageUsage()
                                    } catch { editor.report(error) }
                                }
                                .buttonStyle(.kirie)
                                .help("Copies every referenced file into the project so it can be moved to another Mac. Adds about \(formatBytes(editor.session.package.collectEstimate(for: editor.project))).")
                            }
                            Text("Clearing caches never touches your media, snapshots or exports.").font(Theme.Font.small).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .onAppear { usage = editor.session.package.storageUsage() }
                }

                card("Privacy") {
                    Label("Kirie works without an account and makes no network connections.", systemImage: "lock.shield").font(Theme.Font.body).foregroundStyle(Theme.text)
                    Text("Captions, beat detection, panel detection and subject framing all run on this Mac. There is no analytics or telemetry. Cloud AI providers are not part of this version; when they arrive they will be opt-in, with the provider, model, cost and data sent shown before each request.")
                        .font(Theme.Font.label).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }

                card("Keyboard") {
                    let shortcuts: [(String, String)] = [("Space", "Play / pause"), ("J  K  L", "Reverse, stop, forward"), ("←  →", "Previous / next frame (Shift: one second)"),
                                                          ("⌘B or B", "Split at playhead"), ("⌫  /  ⇧⌫", "Delete / ripple delete"), ("⌘D", "Duplicate"),
                                                          ("M", "Add marker"), ("N", "Toggle snapping"), ("⌘=  ⌘−", "Zoom timeline"), ("⌘Z  ⇧⌘Z", "Undo / redo"),
                                                          ("⌘I  ⌘E", "Import / export"), ("T", "Tap a lyric line (Lyric Studio)")]
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: Theme.Space.xs) {
                        ForEach(shortcuts, id: \.0) { shortcut in
                            HStack {
                                Text(shortcut.0).font(Theme.Font.mono).foregroundStyle(Theme.text).frame(width: 84, alignment: .leading)
                                Text(shortcut.1).font(Theme.Font.label).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                    PlannedNote(text: "Remappable shortcuts with Final Cut Pro and Premiere presets.")
                }

                card("About") {
                    Text("Kirie \(ProjectPackage.appVersion) · project format \(ProjectDomainVersion.schema)").font(Theme.Font.body).foregroundStyle(Theme.text)
                    Text("切り絵 is the Japanese art of cutting pictures from paper. Exports never carry a watermark.").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func row(_ label: String, _ bytes: Int64) -> some View {
        HStack {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.secondary)
            Spacer()
            Text(formatBytes(bytes)).font(Theme.Font.mono).foregroundStyle(Theme.text)
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(Theme.Font.sectionTitle).foregroundStyle(Theme.text)
            content()
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
    }
}

enum ProjectDomainVersion {
    static var schema: Int { ProjectDomain.SchemaVersion.current }
}
