import AppKit
import ComicStudio
import KirieServices
import MediaServices
import ProjectDomain
import SwiftUI

enum ComicSection: String, CaseIterable, Identifiable {
    case story, panels, wireframes, characters, style, reel, montage, lyrics, qa, export
    var id: String { rawValue }

    var title: String {
        switch self {
        case .story: "Story"
        case .panels: "Strip & Panels"
        case .wireframes: "Layout Wireframes"
        case .characters: "Character Library"
        case .style: "Style Lock"
        case .reel: "Reel Builder"
        case .montage: "Montage"
        case .lyrics: "Lyric Studio"
        case .qa: "QA Gate"
        case .export: "Export"
        }
    }

    var symbol: String {
        switch self {
        case .story: "text.book.closed"
        case .panels: "rectangle.split.2x2"
        case .wireframes: "square.dashed"
        case .characters: "person.2"
        case .style: "paintpalette"
        case .reel: "film.stack"
        case .montage: "photo.stack"
        case .lyrics: "music.mic"
        case .qa: "checkmark.seal"
        case .export: "square.and.arrow.up"
        }
    }

    /// Designed but not built yet.
    var planned: Bool { self == .characters || self == .style }
}

/// Comic Studio: a workspace of its own for strips, reels, lyric edits and review. The left rail is
/// the production order, from story to export.
struct ComicStudioView: View {
    @Environment(AppModel.self) private var app
    @Bindable var editor: EditorModel
    @AppStorage("comic.section") private var sectionRaw = ComicSection.panels.rawValue
    @State private var stripID: UUID?

    private var section: ComicSection { ComicSection(rawValue: sectionRaw) ?? .panels }
    private var comic: ComicState? { editor.project.comic }
    var strip: ComicStrip? { comic?.strips.first { $0.id == stripID } ?? comic?.strips.first }

    var body: some View {
        HStack(spacing: 0) {
            rail.frame(width: 204)
            Divider1(vertical: true)
            Group {
                if comic == nil, section != .wireframes {
                    setup
                } else {
                    switch section {
                    case .story: StorySection(editor: editor)
                    case .panels: PanelsSection(editor: editor, strip: strip, selectStrip: { stripID = $0 }, importStrip: importStrip)
                    case .wireframes: WireframeSection(editor: editor)
                    case .characters, .style: plannedSection
                    case .reel: ReelSection(editor: editor, strip: strip) { app.go(.editor) }
                    case .montage: MontageBuilderSection(editor: editor) { app.go(.editor) }
                    case .lyrics: LyricSection(editor: editor) { app.go(.editor) }
                    case .qa: QASection(editor: editor, strip: strip)
                    case .export: ComicExportSection(editor: editor, strip: strip)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.window)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Comic Studio").font(Theme.Font.sectionTitle).foregroundStyle(Theme.text)
                Text(comic?.folderName ?? "Not set up").font(Theme.Font.mono).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.s).padding(.bottom, Theme.Space.s)
            ForEach(Array(ComicSection.allCases.enumerated()), id: \.element) { index, item in
                Button { if !item.planned { sectionRaw = item.rawValue } } label: {
                    HStack(spacing: Theme.Space.s) {
                        Text("\(index + 1)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.tertiary).frame(width: 12, alignment: .trailing)
                        Image(systemName: item.symbol).font(.system(size: 12)).frame(width: 16).foregroundStyle(section == item ? Theme.accent : Theme.secondary)
                        Text(item.title).font(Theme.Font.body).foregroundStyle(section == item ? Theme.text : Theme.secondary)
                        Spacer(minLength: 0)
                        if item.planned { StatusBadge(text: "Soon", tint: Theme.tertiary) }
                        if item == .qa, comic != nil { qaBadge }
                    }
                    .padding(.horizontal, Theme.Space.s).frame(height: Theme.Size.control)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(section == item ? Theme.accentSoft : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(item.planned ? 0.55 : 1)
                .help(item.planned ? "\(item.title) is planned for Phase 2" : item.title)
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
            Spacer()
            if editor.exportLock.isLocked {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Export locked", systemImage: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warning)
                    Text("A strip needs to pass QA.").font(Theme.Font.small).foregroundStyle(Theme.secondary)
                }
                .padding(Theme.Space.s).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.warningSoft))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.warning.opacity(0.5)))
            } else if comic?.strips.isEmpty == false {
                Label("Cleared for export", systemImage: "lock.open").font(Theme.Font.label).foregroundStyle(Theme.success).padding(Theme.Space.s)
            }
        }
        .padding(Theme.Space.s)
        .background(Theme.panel)
    }

    @ViewBuilder private var qaBadge: some View {
        if let state = editor.exportLock.strips.first?.state {
            switch state {
            case .approved: Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.success)
            case .notApproved: Image(systemName: "questionmark.diamond.fill").font(.system(size: 10)).foregroundStyle(Theme.warning)
            case .staleImage, .staleReview, .unverifiable: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.warning)
            }
        }
    }

    private var setup: some View {
        VStack(spacing: Theme.Space.m) {
            EmptyState(symbol: "rectangle.3.group", title: "Turn a comic strip into a reel",
                       message: "Import a strip and Kirie finds its panels, frames each one so nothing is cut off, and builds a panel-by-panel reel. Lyric edits, montages and the QA gate live here too.",
                       actionTitle: "Import a Strip…", action: importStrip)
                .frame(height: 260)
            Button("Set up without a strip") { editor.perform(.comic(command: .enable(number: 1, slug: editor.project.name))) }.buttonStyle(.kirie)
                .help("Use Lyric Studio or Montage without a comic strip")
        }
    }

    private var plannedSection: some View {
        EmptyState(symbol: section.symbol, title: "\(section.title) is not available yet",
                   message: section == .characters
                       ? "Character sheets with outfits, height guides and props, organised by series and attached to image requests, are planned for Phase 2."
                       : "A locked master style reference that is attached to every image request, with a record of what was actually sent, is planned for Phase 2.")
    }

    func importStrip() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a comic strip image"
        panel.prompt = "Import Strip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let result = await editor.session.prepareImport([url])
            do {
                let asset: MediaAsset
                if let imported = result.assets.first {
                    try editor.session.execute(.importAssets(assets: [imported]))
                    asset = imported
                } else if let existing = editor.project.assets.first(where: { $0.reference.absolutePath == url.standardizedFileURL.path }) {
                    asset = existing
                } else {
                    editor.notify(.error, result.failures.first?.reason ?? "The image could not be imported.")
                    return
                }
                let number = (editor.project.comic?.number ?? 1)
                let strip = try editor.session.addStrip(assetID: asset.id, number: number)
                editor.syncFromSession(reload: false)
                stripID = strip.id
                sectionRaw = ComicSection.panels.rawValue
                editor.notify(strip.panels.isEmpty ? .warning : .success,
                              strip.panels.isEmpty ? "No panels were found. Draw them with Add Panel." : "Found \(strip.panels.count) panel\(strip.panels.count == 1 ? "" : "s"). Check them, then build the reel.")
            } catch {
                editor.syncFromSession(reload: false)
                editor.report(error)
            }
        }
    }
}

/// Shared page chrome for Comic Studio sections.
struct ComicPage<Trailing: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Font.workspaceTitle).foregroundStyle(Theme.text)
                    Text(subtitle).font(Theme.Font.label).foregroundStyle(Theme.secondary)
                }
                Spacer()
                trailing()
            }
            .padding(.horizontal, Theme.Space.xl).frame(height: 64)
            Divider1()
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ComicCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let title { Text(title.uppercased()).font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.secondary) }
            content()
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
    }
}

// MARK: Story

struct StorySection: View {
    let editor: EditorModel
    @State private var number = ""
    @State private var slug = ""
    @State private var synopsis = Synopsis()

    var body: some View {
        ComicPage(title: "Story and Synopsis", subtitle: "A strip should explain itself to someone who has never seen the series.") { EmptyView() } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    ComicCard(title: "Project") {
                        HStack(spacing: Theme.Space.s) {
                            KirieField(placeholder: "No.", text: $number, onCommit: commitIdentity).frame(width: 70)
                            KirieField(placeholder: "Short name", text: $slug, onCommit: commitIdentity)
                        }
                        Text("Folder name: \(editor.project.comic?.folderName ?? "")").font(Theme.Font.mono).foregroundStyle(Theme.secondary)
                    }
                    ComicCard(title: "Synopsis") {
                        field("Cast", text: $synopsis.cast, placeholder: "Who is in it")
                        field("Premise", text: $synopsis.premise, placeholder: "Panel 1 states the premise")
                        ForEach(synopsis.panelLines.indices, id: \.self) { index in
                            HStack {
                                field("Panel \(index + 1)", text: Binding(get: { synopsis.panelLines[index] }, set: { synopsis.panelLines[index] = $0 }), placeholder: "One short line")
                                IconButton(symbol: "minus.circle", label: "Remove panel line \(index + 1)", size: 22) { synopsis.panelLines.remove(at: index); commit() }
                            }
                        }
                        HStack {
                            Button { synopsis.panelLines.append(""); commit() } label: { Label("Add panel line", systemImage: "plus") }.buttonStyle(.kirieCompact).disabled(synopsis.panelLines.count >= 5)
                            if !(2...5).contains(synopsis.panelLines.count) { Text("A strip usually has 2–5 panels.").font(Theme.Font.small).foregroundStyle(Theme.warning) }
                        }
                        field("Punchline", text: $synopsis.punchline, placeholder: "The clearest thing in the last panel")
                    }
                }
                .padding(Theme.Space.xl).frame(maxWidth: 720, alignment: .leading)
            }
        }
        .onAppear(perform: load)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.secondary).frame(width: 70, alignment: .leading)
            KirieField(placeholder: placeholder, text: text, onCommit: commit)
        }
    }

    private func load() {
        guard let comic = editor.project.comic else { return }
        number = String(comic.number)
        slug = comic.slug
        synopsis = comic.synopsis
    }

    private func commit() {
        guard let comic = editor.project.comic, comic.synopsis != synopsis else { return }
        editor.perform(.comic(command: .setSynopsis(synopsis: synopsis)), reload: false)
    }

    private func commitIdentity() {
        guard let comic = editor.project.comic, let value = Int(number), value != comic.number || slug != comic.slug else { return }
        editor.perform(.comic(command: .enable(number: value, slug: slug)), reload: false)
    }
}

// MARK: Strip and panels

struct PanelsSection: View {
    @Bindable var editor: EditorModel
    let strip: ComicStrip?
    let selectStrip: (UUID) -> Void
    let importStrip: () -> Void
    @State private var selected: UUID?
    @State private var image: NSImage?
    @State private var manga = false

    var body: some View {
        ComicPage(title: "Strip and Panels", subtitle: "Panels are measured from the picture itself. Drag to correct them; the order here is the reading order.") {
            HStack(spacing: Theme.Space.s) {
                if let comic = editor.project.comic, comic.strips.count > 1, let strip {
                    Picker("Strip", selection: Binding(get: { strip.id }, set: selectStrip)) {
                        ForEach(comic.strips) { item in Text(editor.project.asset(item.assetID)?.name ?? "Strip").tag(item.id) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                Button { importStrip() } label: { Label("Import Strip…", systemImage: "plus") }.buttonStyle(.kirie)
            }
        } content: {
            if let strip {
                HStack(spacing: 0) {
                    canvas(strip)
                    Divider1(vertical: true)
                    side(strip).frame(width: 300)
                }
            } else {
                EmptyState(symbol: "rectangle.split.2x2", title: "No strip yet", message: "Import a comic strip image. Kirie detects its panels and you correct anything it missed.",
                           actionTitle: "Import a Strip…", action: importStrip)
            }
        }
        .task(id: strip?.assetID) { loadImage() }
    }

    private func loadImage() {
        guard let strip, let asset = editor.project.asset(strip.assetID), let url = editor.session.resolver.url(for: asset) else { image = nil; return }
        image = editor.cache.loadImage(url, maxPixel: 2000)
    }

    private func canvas(_ strip: ComicStrip) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Button { redetect(strip) } label: { Label("Detect again", systemImage: "wand.and.rays") }.buttonStyle(.kirieCompact)
                    .help("Run panel detection again. This replaces the current panels.")
                Toggle("Right to left", isOn: $manga).toggleStyle(.checkbox).font(Theme.Font.label).help("Manga reading order")
                Divider1(vertical: true).frame(height: 14)
                Button { addPanel(strip) } label: { Label("Add panel", systemImage: "plus.rectangle") }.buttonStyle(.kirieCompact)
                Button { remove(strip) } label: { Label("Delete panel", systemImage: "minus.rectangle") }.buttonStyle(.kirieCompact).disabled(selected == nil)
                Spacer()
                if strip.approval != nil, editor.exportLock.strips.first(where: { $0.stripID == strip.id })?.state == .approved {
                    Label("Changing a panel will require review again", systemImage: "info.circle").font(Theme.Font.small).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, Theme.Space.m).frame(height: 36).background(Theme.panel)
            Divider1()
            if let image {
                PanelCanvas(image: image, panels: strip.panels, selected: $selected) { updated in
                    editor.perform(.comic(command: .setPanels(stripID: strip.id, panels: updated, paperColor: nil)), reload: false)
                    try? editor.session.refreshSubjects(stripID: strip.id)
                    editor.syncFromSession(reload: false)
                }
                .padding(Theme.Space.l)
                .background(Theme.inset)
            } else {
                EmptyState(symbol: "exclamationmark.triangle", title: "The strip image is missing", message: "Relink it in the Media Library to keep working on this strip.").background(Theme.inset)
            }
        }
    }

    private func side(_ strip: ComicStrip) -> some View {
        let plans = (try? editor.session.framingPlans(stripID: strip.id)) ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("READING ORDER AND FRAMING").font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.secondary)
                if strip.panels.isEmpty { Text("No panels. Use Detect again or Add panel.").font(Theme.Font.label).foregroundStyle(Theme.warning) }
                ForEach(Array(strip.panels.enumerated()), id: \.element.id) { index, panel in
                    let plan = index < plans.count ? plans[index] : nil
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        HStack(spacing: Theme.Space.xs) {
                            Text("\(index + 1)").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text).frame(width: 18)
                            if let plan {
                                StatusBadge(text: plan.subjectSafe ? "Framing PASS" : "Framing FAIL", symbol: plan.subjectSafe ? "checkmark.circle.fill" : "xmark.octagon.fill",
                                            tint: plan.subjectSafe ? Theme.success : Theme.danger)
                            }
                            Spacer()
                            IconButton(symbol: "chevron.up", label: "Read panel \(index + 1) earlier", size: 20) { move(strip, index, by: -1) }.disabled(index == 0)
                            IconButton(symbol: "chevron.down", label: "Read panel \(index + 1) later", size: 20) { move(strip, index, by: 1) }.disabled(index == strip.panels.count - 1)
                        }
                        HStack {
                            Picker("Fit", selection: Binding(get: { panel.fit }, set: { fit in update(strip, index) { $0.fit = fit } })) {
                                Text("Show whole panel").tag(FitMode.contain)
                                Text("Fill the frame").tag(FitMode.cover)
                            }
                            .labelsHidden().controlSize(.small)
                            if panel.focus != nil { Button("Clear focus") { update(strip, index) { $0.focus = nil } }.buttonStyle(.kirieCompact) }
                        }
                        if let plan { Text(plan.note).font(Theme.Font.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    .padding(Theme.Space.s)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(selected == panel.id ? Theme.accentSoft : Theme.elevated))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(selected == panel.id ? Theme.accent : Theme.border))
                    .contentShape(Rectangle())
                    .onTapGesture { selected = panel.id }
                }
                if let selected, let panel = strip.panels.first(where: { $0.id == selected }), let image {
                    Text("SELECTED PANEL").font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.secondary).padding(.top, Theme.Space.s)
                    FocusPicker(image: image, panel: panel) { point in
                        if let index = strip.panels.firstIndex(where: { $0.id == selected }) { update(strip, index) { $0.focus = point } }
                    }
                    Text("Click the preview to set the focal point. The dashed box is what Kirie keeps in frame.").font(Theme.Font.small).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.panel)
    }

    private func update(_ strip: ComicStrip, _ index: Int, _ mutate: (inout ComicPanel) -> Void) {
        var panels = strip.panels
        mutate(&panels[index])
        editor.perform(.comic(command: .setPanels(stripID: strip.id, panels: panels, paperColor: nil)), reload: false)
    }

    private func move(_ strip: ComicStrip, _ index: Int, by offset: Int) {
        var panels = strip.panels
        panels.swapAt(index, index + offset)
        editor.perform(.comic(command: .setPanels(stripID: strip.id, panels: panels, paperColor: nil)), reload: false)
    }

    private func addPanel(_ strip: ComicStrip) {
        let panel = ComicPanel(rect: UnitRect(x: 0.3, y: 0.4, width: 0.4, height: 0.2))
        editor.perform(.comic(command: .setPanels(stripID: strip.id, panels: strip.panels + [panel], paperColor: nil)), reload: false)
        selected = panel.id
    }

    private func remove(_ strip: ComicStrip) {
        editor.perform(.comic(command: .setPanels(stripID: strip.id, panels: strip.panels.filter { $0.id != selected }, paperColor: nil)), reload: false)
        selected = nil
    }

    private func redetect(_ strip: ComicStrip) {
        do {
            let count = try editor.session.redetectPanels(stripID: strip.id, rightToLeft: manga)
            editor.syncFromSession(reload: false)
            selected = nil
            editor.notify(count == 0 ? .warning : .success, count == 0 ? "No panels were found." : "Found \(count) panel\(count == 1 ? "" : "s").")
        } catch { editor.report(error) }
    }
}

/// The strip with editable panel boundaries: drag a panel to move it, drag a corner to resize it.
struct PanelCanvas: View {
    let image: NSImage
    let panels: [ComicPanel]
    @Binding var selected: UUID?
    let commit: ([ComicPanel]) -> Void
    @State private var draft: [ComicPanel]?
    @State private var origin: UnitRect?

    private var shown: [ComicPanel] { draft ?? panels }

    var body: some View {
        GeometryReader { geometry in
            let aspect = image.size.width / max(1, image.size.height)
            let width = min(geometry.size.width, geometry.size.height * aspect)
            let size = CGSize(width: width, height: width / aspect)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                    .overlay(Rectangle().strokeBorder(Theme.border))
                    .onTapGesture { selected = nil }
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, panel in
                    let rect = CGRect(x: panel.rect.x * size.width, y: panel.rect.y * size.height, width: panel.rect.width * size.width, height: panel.rect.height * size.height)
                    let isSelected = selected == panel.id
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(isSelected ? Theme.accent.opacity(0.10) : Color.clear)
                        Rectangle().strokeBorder(isSelected ? Theme.accent : Theme.accent.opacity(0.75), style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, dash: isSelected ? [] : [6, 4]))
                        Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Theme.onAccent)
                            .frame(width: 20, height: 20).background(Circle().fill(Theme.accent)).padding(4)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            selected = panel.id
                            let start = origin ?? panel.rect
                            origin = start
                            var moved = start
                            moved.x = min(max(0, start.x + value.translation.width / size.width), 1 - start.width)
                            moved.y = min(max(0, start.y + value.translation.height / size.height), 1 - start.height)
                            apply(panel.id, moved)
                        }
                        .onEnded { _ in finish() })
                    .onTapGesture { selected = panel.id }
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Circle().fill(Theme.accent).frame(width: 12, height: 12).overlay(Circle().strokeBorder(.white, lineWidth: 1.5)).offset(x: 6, y: 6)
                                .gesture(DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        let start = origin ?? panel.rect
                                        origin = start
                                        var resized = start
                                        resized.width = min(max(0.03, start.width + value.translation.width / size.width), 1 - start.x)
                                        resized.height = min(max(0.03, start.height + value.translation.height / size.height), 1 - start.y)
                                        apply(panel.id, resized)
                                    }
                                    .onEnded { _ in finish() })
                                .help("Drag to resize")
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if isSelected {
                            Circle().fill(Theme.accent).frame(width: 12, height: 12).overlay(Circle().strokeBorder(.white, lineWidth: 1.5)).offset(x: -6, y: -6)
                                .gesture(DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        let start = origin ?? panel.rect
                                        origin = start
                                        var resized = start
                                        let dx = min(max(-start.x, value.translation.width / size.width), start.width - 0.03)
                                        let dy = min(max(-start.y, value.translation.height / size.height), start.height - 0.03)
                                        resized.x = start.x + dx; resized.width = start.width - dx
                                        resized.y = start.y + dy; resized.height = start.height - dy
                                        apply(panel.id, resized)
                                    }
                                    .onEnded { _ in finish() })
                        }
                    }
                    .offset(x: rect.minX, y: rect.minY)
                    .accessibilityLabel("Panel \(index + 1)")
                }
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func apply(_ id: UUID, _ rect: UnitRect) {
        var next = draft ?? panels
        if let index = next.firstIndex(where: { $0.id == id }) { next[index].rect = rect.clamped(minSize: 0.02) }
        draft = next
    }

    private func finish() {
        origin = nil
        if let draft, draft != panels { commit(draft) }
        draft = nil
    }
}

/// One panel, enlarged. Click to set the focal point; the dashed box is the detected content.
struct FocusPicker: View {
    let image: NSImage
    let panel: ComicPanel
    let setFocus: (UnitPoint2D) -> Void

    var body: some View {
        if let cropped = crop() {
            GeometryReader { geometry in
                let aspect = cropped.size.width / max(1, cropped.size.height)
                let width = min(geometry.size.width, geometry.size.height * aspect)
                let size = CGSize(width: width, height: width / aspect)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: cropped).resizable().frame(width: size.width, height: size.height)
                    if let subject = panel.subject {
                        Rectangle().strokeBorder(Theme.success, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: subject.width * size.width, height: subject.height * size.height)
                            .offset(x: subject.x * size.width, y: subject.y * size.height)
                    }
                    let focus = panel.focus ?? panel.subject.map { UnitPoint2D(x: $0.midX, y: $0.midY) } ?? .center
                    Image(systemName: "scope").font(.system(size: 16, weight: .medium)).foregroundStyle(panel.focus == nil ? Theme.secondary : Theme.accent)
                        .offset(x: focus.x * size.width - 8, y: focus.y * size.height - 8)
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    setFocus(UnitPoint2D(x: min(1, max(0, location.x / size.width)), y: min(1, max(0, location.y / size.height))))
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 190)
        }
    }

    private func crop() -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rect = CGRect(x: panel.rect.x * Double(cg.width), y: panel.rect.y * Double(cg.height), width: panel.rect.width * Double(cg.width), height: panel.rect.height * Double(cg.height)).integral
        guard let piece = cg.cropping(to: rect) else { return nil }
        return NSImage(cgImage: piece, size: NSSize(width: piece.width, height: piece.height))
    }
}

// MARK: Wireframes

struct WireframeSection: View {
    let editor: EditorModel
    @State private var count = 4

    var body: some View {
        let wireframe = ComicSheets.wireframe(panelCount: count)
        ComicPage(title: "Layout Wireframes", subtitle: "A numbered page layout plus a plain-language description to guide drawing or prompting.") {
            Picker("Panels", selection: $count) { ForEach(2...5, id: \.self) { Text("\($0) panels").tag($0) } }.labelsHidden().pickerStyle(.segmented).frame(width: 300)
        } content: {
            if let wireframe {
                HStack(alignment: .top, spacing: Theme.Space.xl) {
                    Image(nsImage: NSImage(cgImage: wireframe.image, size: NSSize(width: wireframe.image.width, height: wireframe.image.height)))
                        .resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 520)
                        .overlay(Rectangle().strokeBorder(Theme.border))
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ComicCard(title: "Description") {
                            Text(wireframe.description).font(Theme.Font.mono).foregroundStyle(Theme.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(wireframe.description, forType: .string)
                                editor.notify(.success, "Layout description copied")
                            } label: { Label("Copy description", systemImage: "doc.on.doc") }.buttonStyle(.kirie)
                            Button {
                                let panel = NSSavePanel()
                                panel.nameFieldStringValue = "layout-\(count)-panels.png"
                                panel.allowedContentTypes = [.png]
                                if panel.runModal() == .OK, let url = panel.url {
                                    if Thumbnailer.write(wireframe.image, to: url) { editor.notify(.success, "Saved \(url.lastPathComponent)") } else { editor.notify(.error, "The image could not be saved.") }
                                }
                            } label: { Label("Save image…", systemImage: "square.and.arrow.down") }.buttonStyle(.kirie)
                        }
                        Text("Drawn rows rarely land exactly on the wireframe. That is fine: Kirie measures the real panel borders when you import the finished strip.")
                            .font(Theme.Font.label).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 420)
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: Reel builder

struct ReelSection: View {
    @Bindable var editor: EditorModel
    let strip: ComicStrip?
    let openEditor: () -> Void
    @AppStorage("comic.reel.seconds") private var seconds = 3.6
    @AppStorage("comic.reel.push") private var push = 0.06
    @AppStorage("comic.reel.reveal") private var reveal = true
    @AppStorage("comic.reel.revealSeconds") private var revealSeconds = 3.2
    @AppStorage("comic.reel.transition") private var transition = "cut"
    @State private var endCard = EndCard()

    private var options: StripReelOptions {
        var options = StripReelOptions(perPanel: RationalTime(seconds: seconds), maxZoom: 1 + push, revealFullStrip: reveal, fullStripDuration: RationalTime(seconds: revealSeconds))
        if transition == "vary" { options.varyTransitions = true } else if let type = TransitionType(rawValue: transition) { options.transition = Transition(type: type) }
        return options
    }

    var body: some View {
        ComicPage(title: "Reel Builder", subtitle: "Each panel full-screen with gentle motion, then the whole strip. The result is an ordinary timeline you can keep editing.") {
            Button {
                guard let strip else { return }
                do {
                    if endCard != editor.project.comic?.endCard { try editor.session.execute(.comic(command: .setEndCard(endCard: endCard))) }
                    let sequence = try editor.session.buildStripReel(stripID: strip.id, options: options)
                    editor.syncFromSession()
                    editor.notify(.success, String(format: "Built “%@”: %d clips, %.1f s", sequence.name, sequence.mainTrack?.clips.count ?? 0, sequence.duration.seconds))
                    openEditor()
                } catch { editor.syncFromSession(reload: false); editor.report(error) }
            } label: { Label("Build Reel", systemImage: "film.stack") }
            .buttonStyle(.kiriePrimary).disabled(strip == nil || strip?.panels.isEmpty == true)
        } content: {
            if let strip, !strip.panels.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        ComicCard(title: "Timing and motion") {
                            PropertySlider(label: "Per panel", value: $seconds, range: 1...10, format: "%.1f", unit: "s")
                            PropertySlider(label: "Push-in", value: $push, range: 0...0.2, format: "%.0f", unit: "%", displayScale: 100)
                            Text("The push-in is reduced automatically on any panel where it would crop the subject.").font(Theme.Font.small).foregroundStyle(Theme.tertiary)
                            PropertyRow(label: "Between") {
                                Picker("Transition", selection: $transition) {
                                    Text("Hard cut").tag("cut")
                                    Text("A different one each time").tag("vary")
                                    Divider()
                                    ForEach(TransitionType.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                                }
                                .labelsHidden().controlSize(.small).frame(width: 210)
                            }
                        }
                        ComicCard(title: "Ending") {
                            Toggle("Reveal the full strip at the end", isOn: $reveal).toggleStyle(.checkbox).font(Theme.Font.label)
                            if reveal { PropertySlider(label: "Hold for", value: $revealSeconds, range: 1...8, format: "%.1f", unit: "s") }
                            Toggle("Signature end card", isOn: $endCard.enabled).toggleStyle(.checkbox).font(Theme.Font.label)
                            if endCard.enabled {
                                KirieField(placeholder: "Your handle or sign-off", text: $endCard.text)
                                HStack {
                                    PropertySlider(label: "Length", value: Binding(get: { endCard.duration.seconds }, set: { endCard.duration = RationalTime(seconds: $0) }), range: 0.5...6, format: "%.1f", unit: "s")
                                    ColorPicker("Card", selection: Binding(get: { endCard.background.color }, set: { endCard.background = RGBAColor($0) }), supportsOpacity: false).labelsHidden()
                                    ColorPicker("Text", selection: Binding(get: { endCard.textColor.color }, set: { endCard.textColor = RGBAColor($0) }), supportsOpacity: false).labelsHidden()
                                }
                            }
                        }
                        let total = Double(strip.panels.count) * seconds + (reveal ? revealSeconds : 0) + (endCard.enabled && !endCard.text.isEmpty ? endCard.duration.seconds : 0)
                        Text(String(format: "%d panels · about %.1f s on a %d×%d canvas", strip.panels.count, total, editor.project.canvas.width, editor.project.canvas.height))
                            .font(Theme.Font.mono).foregroundStyle(Theme.secondary)
                    }
                    .padding(Theme.Space.xl).frame(maxWidth: 620, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                EmptyState(symbol: "film.stack", title: "No panels to build from", message: "Import a strip and check its panels in Strip & Panels first.")
            }
        }
        .onAppear { endCard = editor.project.comic?.endCard ?? EndCard() }
    }
}
