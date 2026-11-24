import AppKit
import ProjectDomain
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 0) {
            SidebarView(collapsed: $sidebarCollapsed)
            Divider1(vertical: true)
            ZStack(alignment: .bottom) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.window)
                if let editor = app.editor {
                    ToastStack(editor: editor)
                }
                if let busy = app.busyMessage {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(Theme.Font.body)
                    }
                    .padding(Theme.Space.m)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Theme.elevated))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.borderStrong))
                    .padding(.bottom, Theme.Space.xl)
                }
            }
        }
        .background(Theme.window)
        .navigationTitle(title)
        .toolbar { toolbar }
        .sheet(isPresented: $app.showNewProject) { NewProjectSheet() }
        .sheet(isPresented: exportBinding) {
            if let editor = app.editor { ExportSheet(editor: editor) }
        }
        .alert("Kirie", isPresented: Binding(get: { app.alertMessage != nil }, set: { if !$0 { app.alertMessage = nil } })) {
            Button("OK") { app.alertMessage = nil }
        } message: {
            Text(app.alertMessage ?? "")
        }
        .kirieAnimation(sidebarCollapsed, reduceMotion: reduceMotion)
    }

    private var exportBinding: Binding<Bool> {
        Binding(get: { app.editor?.showExport ?? false }, set: { app.editor?.showExport = $0 })
    }

    private var title: String {
        if app.destination.needsProject, let editor = app.editor { return editor.project.name }
        return app.destination.title
    }

    @ViewBuilder private var content: some View {
        switch app.destination {
        case .home: ProjectHubView(mode: .home)
        case .projects: ProjectHubView(mode: .all)
        case .library:
            if let editor = app.editor { MediaLibraryView(editor: editor) } else { noProject }
        case .editor:
            if let editor = app.editor { EditorView(editor: editor) } else { noProject }
        case .comic:
            if let editor = app.editor { ComicStudioView(editor: editor) } else { noProject }
        case .templates: TemplatesView()
        case .exports: ExportQueueView()
        case .settings: SettingsView()
        }
    }

    private var noProject: some View {
        EmptyState(symbol: "film.stack", title: "No project open", message: "Create a project or open one from Home to start editing.",
                   actionTitle: "New Project") { app.showNewProject = true }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            IconButton(symbol: "sidebar.leading", label: sidebarCollapsed ? "Show sidebar" : "Hide sidebar") { sidebarCollapsed.toggle() }
        }
        if let editor = app.editor, app.destination.needsProject {
            ToolbarItemGroup(placement: .navigation) {
                IconButton(symbol: "arrow.uturn.backward", label: editor.undoLabel.map { "Undo \($0)" } ?? "Undo", shortcutHint: "⌘Z") { editor.undo() }
                    .disabled(!editor.canUndo)
                IconButton(symbol: "arrow.uturn.forward", label: editor.redoLabel.map { "Redo \($0)" } ?? "Redo", shortcutHint: "⇧⌘Z") { editor.redo() }
                    .disabled(!editor.canRedo)
                SaveIndicator(state: editor.saveState)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if !editor.activity.isEmpty {
                    HStack(spacing: Theme.Space.xs) {
                        ProgressView().controlSize(.small)
                        Text(editor.activity.last ?? "").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                    }
                }
                if editor.exportLock.isLocked {
                    Button { app.go(.comic) } label: {
                        StatusBadge(text: "Export locked", symbol: "lock.fill", tint: Theme.warning)
                    }
                    .buttonStyle(.plain)
                    .help(editor.exportLock.reasons.joined(separator: "\n"))
                }
                Button {
                    editor.showExport = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.kiriePrimary)
                .help("Export (⌘E)")
            }
        }
    }
}

struct SaveIndicator: View {
    let state: SaveState

    var body: some View {
        HStack(spacing: 4) {
            switch state {
            case .saved: Image(systemName: "checkmark.circle").foregroundStyle(Theme.tertiary)
            case .unsaved: Image(systemName: "circle.dotted").foregroundStyle(Theme.tertiary)
            case .saving: ProgressView().controlSize(.mini)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            }
            Text(state.label).font(Theme.Font.label).foregroundStyle(state == .saved || state == .unsaved || state == .saving ? Theme.secondary : Theme.danger)
        }
        .padding(.horizontal, Theme.Space.xs)
        .help({
            if case .failed(let message) = state { return message }
            return "Kirie saves automatically after every change"
        }())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Save status: \(state.label)")
    }
}

struct ToastStack: View {
    let editor: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            ForEach(editor.toasts) { toast in
                ToastView(toast: toast) { editor.dismiss(toast) }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, Theme.Space.xl)
        .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.standard), value: editor.toasts)
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Binding var collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            group([.home, .projects])
            sectionLabel("Project")
            group([.editor, .comic, .library])
            sectionLabel("Output")
            group([.templates, .exports])
            Spacer()
            group([.settings])
        }
        .padding(.vertical, Theme.Space.s)
        .padding(.horizontal, Theme.Space.s)
        .frame(width: collapsed ? Theme.Size.sidebarCollapsed : Theme.Size.sidebar)
        .background(Theme.panel)
    }

    @ViewBuilder private func sectionLabel(_ text: String) -> some View {
        if collapsed {
            Divider1().padding(.vertical, Theme.Space.xs)
        } else {
            Text(text.uppercased()).font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.tertiary)
                .padding(.horizontal, Theme.Space.s).padding(.top, Theme.Space.m).padding(.bottom, Theme.Space.xxs)
        }
    }

    private func group(_ items: [Destination]) -> some View {
        ForEach(items) { item in SidebarRow(destination: item, collapsed: collapsed) }
    }
}

struct SidebarRow: View {
    @Environment(AppModel.self) private var app
    let destination: Destination
    let collapsed: Bool
    @State private var hovering = false

    private var available: Bool { !destination.needsProject || app.editor != nil }
    private var selected: Bool { app.destination == destination }
    private var running: Int { destination == .exports ? app.exportJobs.filter { $0.state == .running }.count : 0 }

    var body: some View {
        Button { app.go(destination) } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: destination.symbol).font(.system(size: 13, weight: .medium)).frame(width: 18)
                    .foregroundStyle(selected ? Theme.accent : Theme.secondary)
                if !collapsed {
                    Text(destination.title).font(Theme.Font.body).foregroundStyle(selected ? Theme.text : Theme.secondary)
                    Spacer(minLength: 0)
                    if destination == .templates { StatusBadge(text: "Soon", tint: Theme.tertiary) }
                    if running > 0 { StatusBadge(text: "\(running)", tint: Theme.accent) }
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(height: Theme.Size.control)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(selected ? Theme.accentSoft : hovering && available ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(available ? destination.title : "\(destination.title): open a project first")
        .accessibilityLabel(destination.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct TemplatesView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Templates").font(Theme.Font.workspaceTitle).foregroundStyle(Theme.text)
            EmptyState(symbol: "square.on.square.dashed", title: "Templates are not available yet",
                       message: "Reusable project templates, caption presets and brand kits are planned for Phase 2. Until then, duplicate a project in Finder to reuse it as a starting point.")
        }
        .padding(Theme.Space.xl)
    }
}
