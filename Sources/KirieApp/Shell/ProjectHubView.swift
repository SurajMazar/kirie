import AppKit
import Persistence
import ProjectDomain
import SwiftUI

struct ProjectHubView: View {
    enum Mode { case home, all }
    let mode: Mode
    @Environment(AppModel.self) private var app
    @State private var search = ""
    @AppStorage("hubGrid") private var grid = true
    @AppStorage("hubShowArchived") private var showArchived = false
    @AppStorage("onboardingDismissed") private var onboardingDismissed = false

    private var projects: [IndexedProject] {
        app.recents.filter { (showArchived && mode == .all) || !$0.archived }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                if mode == .home, !onboardingDismissed { OnboardingCard { onboardingDismissed = true } }
                if projects.isEmpty {
                    emptyState.frame(height: 320)
                } else {
                    if mode == .home, search.isEmpty, let latest = projects.first {
                        section("Continue editing") { ContinueCard(project: latest) }
                    }
                    section(mode == .home ? "Recent projects" : "All projects", trailing: AnyView(viewToggle)) {
                        let shown = mode == .home ? Array(projects.prefix(8)) : projects
                        if grid {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: Theme.Space.l)], alignment: .leading, spacing: Theme.Space.l) {
                                ForEach(shown) { ProjectCard(project: $0) }
                            }
                        } else {
                            VStack(spacing: 0) { ForEach(shown) { ProjectListRow(project: $0) } }
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Theme.panel))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
                        }
                    }
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(mode == .home ? "Kirie" : "Projects").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.text)
                    if mode == .home { Text("切り絵").font(.system(size: 13)).foregroundStyle(Theme.tertiary) }
                }
                Text(mode == .home ? "Cut, caption and export. Comics included." : "\(projects.count) project\(projects.count == 1 ? "" : "s") in \(app.projectFolder.lastPathComponent)")
                    .font(Theme.Font.body).foregroundStyle(Theme.secondary)
            }
            Spacer()
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary).font(.system(size: 11))
                TextField("Search projects", text: $search).textFieldStyle(.plain).font(Theme.Font.body).frame(width: 170)
            }
            .padding(.horizontal, Theme.Space.s).frame(height: Theme.Size.control)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.inset))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
            Button("Open…") { app.chooseProjectToOpen() }.buttonStyle(.kirie).help("Open a project from disk (⌘O)")
            Button { app.showNewProject = true } label: { Label("New Project", systemImage: "plus") }.buttonStyle(.kiriePrimary).help("New project (⌘N)")
        }
    }

    private var viewToggle: some View {
        HStack(spacing: Theme.Space.xs) {
            if mode == .all {
                Toggle("Archived", isOn: $showArchived).toggleStyle(.checkbox).font(Theme.Font.label).foregroundStyle(Theme.secondary)
                Button("Rescan folder") { app.rescanProjectFolder() }.buttonStyle(.kirieCompact).help("Look for projects in \(app.projectFolder.path)")
            }
            IconButton(symbol: "square.grid.2x2", label: "Grid view", active: grid, size: 24) { grid = true }
            IconButton(symbol: "list.bullet", label: "List view", active: !grid, size: 24) { grid = false }
        }
    }

    private func section<Content: View>(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text(title).font(Theme.Font.sectionTitle).foregroundStyle(Theme.text)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !search.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "No project matches “\(search)”", message: "Check the spelling, or clear the search to see every project.")
        } else {
            VStack(spacing: Theme.Space.m) {
                EmptyState(symbol: "film.stack", title: "No projects yet",
                           message: "Start a Reel in a few seconds, or build the demo project to see a finished timeline, a comic strip reel and a lyric edit.",
                           actionTitle: "New Project") { app.showNewProject = true }
                    .frame(height: 220)
                Button("Build the demo project") { app.createDemo() }.buttonStyle(.kirie)
            }
        }
    }
}

struct ProjectPoster: View {
    @Environment(AppModel.self) private var app
    let project: IndexedProject

    var body: some View {
        ZStack {
            Theme.inset
            if let image = app.posters[project.path] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                // No frame rendered yet: show the canvas shape.
                let aspect = CGFloat(max(1, project.width)) / CGFloat(max(1, project.height))
                RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .aspectRatio(aspect, contentMode: .fit).padding(Theme.Space.l)
                    .overlay(Image(systemName: project.isComic ? "rectangle.3.group" : "film").foregroundStyle(Theme.tertiary))
            }
        }
    }
}

struct ProjectMenu: View {
    @Environment(AppModel.self) private var app
    let project: IndexedProject

    var body: some View {
        Button("Open") { app.openProject(at: project.url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
        Divider()
        Button(project.archived ? "Unarchive" : "Archive") { app.setArchived(!project.archived, project) }
        Button("Remove from List") { app.forget(project) }
    }
}

struct ProjectCard: View {
    @Environment(AppModel.self) private var app
    let project: IndexedProject
    @State private var hovering = false

    var body: some View {
        Button { app.openProject(at: project.url) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ProjectPoster(project: project).frame(height: 170).clipped()
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Space.xs) {
                        Text(project.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        if project.isComic { StatusBadge(text: "Comic", tint: Theme.accent) }
                        if project.archived { StatusBadge(text: "Archived", tint: Theme.tertiary) }
                    }
                    Text(verbatim: "\(project.width)×\(project.height) · \(formatDuration(project.duration))").font(Theme.Font.small).foregroundStyle(Theme.secondary)
                    Text(project.modifiedAt.formatted(.relative(presentation: .named))).font(Theme.Font.small).foregroundStyle(Theme.tertiary)
                }
                .padding(Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(hovering ? Theme.accent.opacity(0.6) : Theme.border))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { ProjectMenu(project: project) }
        .accessibilityLabel("\(project.name), \(project.width) by \(project.height), \(formatDuration(project.duration))")
    }
}

struct ProjectListRow: View {
    @Environment(AppModel.self) private var app
    let project: IndexedProject
    @State private var hovering = false

    var body: some View {
        Button { app.openProject(at: project.url) } label: {
            HStack(spacing: Theme.Space.m) {
                ProjectPoster(project: project).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
                Text(project.name).font(Theme.Font.body).foregroundStyle(Theme.text).frame(minWidth: 160, alignment: .leading)
                if project.isComic { StatusBadge(text: "Comic", tint: Theme.accent) }
                Spacer()
                Text(verbatim: "\(project.width)×\(project.height)").font(Theme.Font.mono).foregroundStyle(Theme.secondary).frame(width: 90, alignment: .trailing)
                Text(formatDuration(project.duration)).font(Theme.Font.mono).foregroundStyle(Theme.secondary).frame(width: 50, alignment: .trailing)
                Text(project.modifiedAt.formatted(date: .abbreviated, time: .shortened)).font(Theme.Font.label).foregroundStyle(Theme.tertiary).frame(width: 150, alignment: .trailing)
            }
            .padding(.horizontal, Theme.Space.m).frame(height: 56)
            .background(hovering ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { ProjectMenu(project: project) }
        .overlay(alignment: .bottom) { Divider1() }
    }
}

struct ContinueCard: View {
    @Environment(AppModel.self) private var app
    let project: IndexedProject

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            ProjectPoster(project: project).frame(width: 150, height: 150).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(project.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Text(verbatim: "\(project.width)×\(project.height) · \(formatDuration(project.duration)) · edited \(project.modifiedAt.formatted(.relative(presentation: .named)))")
                    .font(Theme.Font.body).foregroundStyle(Theme.secondary)
                Spacer().frame(height: Theme.Space.s)
                HStack {
                    Button { app.openProject(at: project.url) } label: { Label("Continue", systemImage: "play.fill") }.buttonStyle(.kiriePrimary)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }.buttonStyle(.kirie)
                }
            }
            Spacer()
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
        .contextMenu { ProjectMenu(project: project) }
    }
}

/// Short, dismissible first-run guide.
struct OnboardingCard: View {
    @Environment(AppModel.self) private var app
    let dismiss: () -> Void
    private let steps: [(String, String, String)] = [
        ("plus.rectangle", "Create", "Pick a canvas. 9:16 is one click."),
        ("square.and.arrow.down", "Import", "Drop in video, audio and pictures."),
        ("scissors", "Edit", "Split with ⌘B, trim by dragging clip edges."),
        ("rectangle.3.group", "Comic Studio", "Turn a strip into a panel-by-panel reel."),
        ("square.and.arrow.up", "Export", "A verified file, never watermarked."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Getting started").font(Theme.Font.sectionTitle).foregroundStyle(Theme.text)
                Spacer()
                Button("Build the demo project") { app.createDemo() }.buttonStyle(.kirieCompact)
                IconButton(symbol: "xmark", label: "Dismiss getting started", size: 22, action: dismiss)
            }
            HStack(alignment: .top, spacing: Theme.Space.m) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        HStack(spacing: Theme.Space.xs) {
                            Text("\(index + 1)").font(Theme.Font.mono).foregroundStyle(Theme.tertiary)
                            Image(systemName: step.0).foregroundStyle(Theme.accent).font(.system(size: 13))
                        }
                        Text(step.1).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                        Text(step.2).font(Theme.Font.label).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(Theme.Space.l)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
    }
}

struct NewProjectSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Untitled Reel"
    @State private var presetID = "vertical"
    @State private var customWidth = "1080"
    @State private var customHeight = "1920"
    @State private var frameRate = FrameRate.fps30
    @State private var colorSpace = ColorSpaceTag.rec709
    @State private var comic = false
    @State private var folder: URL?

    private var size: (Int, Int)? {
        if presetID == "custom" {
            guard let w = Int(customWidth), let h = Int(customHeight) else { return nil }
            return (w, h)
        }
        return CanvasPreset.named(presetID).map { ($0.width, $0.height) }
    }

    private var problem: String? {
        guard let size else { return "Enter a width and height in pixels." }
        if size.0 < 16 || size.1 < 16 || size.0 > 8192 || size.1 > 8192 { return "Sizes must be between 16 and 8192 pixels." }
        if size.0 % 2 != 0 || size.1 % 2 != 0 { return "Width and height must be even numbers." }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the project a name." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("New Project").font(Theme.Font.workspaceTitle).foregroundStyle(Theme.text)
            KirieField(placeholder: "Project name", text: $name)

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("CANVAS").font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.secondary)
                HStack(spacing: Theme.Space.s) {
                    ForEach(CanvasPreset.all) { preset in
                        CanvasChoice(title: preset.name, subtitle: preset.ratioLabel, aspect: CGFloat(preset.width) / CGFloat(preset.height), selected: presetID == preset.id) {
                            presetID = preset.id
                        }
                    }
                    CanvasChoice(title: "Custom", subtitle: "W × H", aspect: nil, selected: presetID == "custom") { presetID = "custom" }
                }
                if presetID == "custom" {
                    HStack(spacing: Theme.Space.s) {
                        KirieField(placeholder: "Width", text: $customWidth).frame(width: 90)
                        Text("×").foregroundStyle(Theme.secondary)
                        KirieField(placeholder: "Height", text: $customHeight).frame(width: 90)
                        Text("pixels").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                    }
                } else if let size {
                    Text(verbatim: "\(size.0) × \(size.1) pixels").font(Theme.Font.mono).foregroundStyle(Theme.secondary)
                }
            }

            HStack(spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("FRAME RATE").font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.secondary)
                    Picker("Frame rate", selection: $frameRate) {
                        ForEach(FrameRate.common, id: \.self) { Text("\($0.description) fps").tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("COLOUR SPACE").font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.secondary)
                    Picker("Colour space", selection: $colorSpace) {
                        ForEach(ColorSpaceTag.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 190)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("LOCATION").font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.secondary)
                HStack {
                    Image(systemName: "folder").foregroundStyle(Theme.secondary)
                    Text((folder ?? app.projectFolder).path).font(Theme.Font.label).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK { folder = panel.url }
                    }
                    .buttonStyle(.kirieCompact)
                }
            }

            if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(Theme.Font.label).foregroundStyle(Theme.warning) }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.kirie).keyboardShortcut(.cancelAction)
                Button("Create") {
                    guard let size else { return }
                    app.createProject(name: name, canvas: CanvasSettings(width: size.0, height: size.1, frameRate: frameRate, colorSpace: colorSpace),
                                      in: folder ?? app.projectFolder)
                    dismiss()
                }
                .buttonStyle(.kiriePrimary).keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 640)
        .background(Theme.window)
    }
}

struct CanvasChoice: View {
    let title: String
    let subtitle: String
    let aspect: CGFloat?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.xs) {
                ZStack {
                    if let aspect {
                        RoundedRectangle(cornerRadius: 2).fill(selected ? Theme.accentSoft : Theme.inset)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(selected ? Theme.accent : Theme.borderStrong))
                            .aspectRatio(aspect, contentMode: .fit)
                    } else {
                        Image(systemName: "slider.horizontal.3").foregroundStyle(selected ? Theme.accent : Theme.secondary)
                    }
                }
                .frame(width: 52, height: 52)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                Text(subtitle).font(Theme.Font.small).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.s)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(selected ? Theme.accentSoft : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(selected ? Theme.accent : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
