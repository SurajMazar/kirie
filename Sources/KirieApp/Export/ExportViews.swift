import AppKit
import KirieServices
import MediaServices
import ProjectDomain
import RenderEngine
import SwiftUI

struct ExportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let editor: EditorModel
    @State private var preset: ExportPreset = .builtIn[0]
    @State private var wholeTimeline = true
    @State private var rangeStart = "0"
    @State private var rangeEnd = ""
    @State private var silent = false
    @State private var reduceMotion = false
    @State private var destination: URL?
    @State private var fileName = ""
    @State private var preview: NSImage?
    @State private var job: ExportJob?

    private var duration: RationalTime { range?.duration ?? editor.sequence.duration }
    private var canvasAspect: Double { editor.project.canvas.aspectRatio }
    private var letterboxed: Bool { abs(Double(preset.width) / Double(preset.height) - canvasAspect) > 0.01 }
    private var withheld: [MediaAsset] {
        let used = Set(editor.sequence.allClips.filter { !$0.audio.muted }.compactMap(\.assetID))
        return editor.project.assets.filter { used.contains($0.id) && $0.metadata.hasAudio && $0.rights.status == .commercialUnlicensed }
    }
    private var hasAudio: Bool {
        guard !silent else { return false }
        return editor.sequence.tracks.contains { track in
            !track.muted && track.clips.contains { clip in
                !clip.audio.muted && (clip.kind == .audio || clip.kind == .video) && editor.project.asset(clip.assetID)?.metadata.hasAudio == true
                    && editor.project.asset(clip.assetID)?.rights.status != .commercialUnlicensed
            }
        }
    }

    private var range: TimeRange? {
        guard !wholeTimeline else { return nil }
        let start = RationalTime(seconds: max(0, Double(rangeStart) ?? 0)).rounded(toFrame: preset.frameRate)
        let end = RationalTime(seconds: Double(rangeEnd) ?? editor.sequence.duration.seconds).rounded(toFrame: preset.frameRate)
        let clampedEnd = RationalTime.min(end, editor.sequence.duration)
        return clampedEnd > start ? TimeRange(start: start, end: clampedEnd) : nil
    }

    private var problems: [String] {
        var list = preset.validationProblems()
        if editor.sequence.duration.isZero { list.append("The timeline is empty.") }
        if !wholeTimeline, range == nil { list.append("The range end must be after its start, inside the timeline.") }
        if !Exporter.encoderAvailable(preset.codec) { list.append("\(preset.codec.displayName) encoding is not available on this Mac.") }
        if !editor.missingMedia.isEmpty { list.append("Missing media: \(editor.missingMedia.map(\.name).joined(separator: ", ")). Relink it first.") }
        if fileName.trimmingCharacters(in: .whitespaces).isEmpty { list.append("Enter a file name.") }
        return list
    }

    private var outputURL: URL {
        let folder = destination ?? editor.session.package.exportsURL
        let cleaned = fileName.map { $0 == "/" || $0 == ":" ? "-" : $0 }
        return folder.appendingPathComponent("\(String(cleaned)).\(preset.container.fileExtension)")
    }

    var body: some View {
        VStack(spacing: 0) {
            if let job {
                ExportProgressView(job: job, editor: editor, another: { self.job = nil }, close: { dismiss() })
            } else {
                form
            }
        }
        .frame(width: 780, height: 560)
        .background(Theme.window)
        .onAppear {
            preset = ExportPreset.named(editor.project.exportPresetID) ?? ExportPreset.matching(editor.project.canvas)
            if preset.id != "custom" { preset.frameRate = editor.project.canvas.frameRate }
            fileName = editor.project.sequences.count > 1 ? "\(editor.project.name) – \(editor.sequence.name)" : editor.project.name
            rangeEnd = String(format: "%.2f", editor.sequence.duration.seconds)
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            renderPreview()
        }
        .onChange(of: preset.id) { _, _ in renderPreview() }
    }

    private var form: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Export").font(Theme.Font.workspaceTitle).foregroundStyle(Theme.text)
                Text(editor.sequence.name).font(Theme.Font.body).foregroundStyle(Theme.secondary)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.xl).frame(height: 56)
            Divider1()
            HStack(spacing: 0) {
                presetList.frame(width: 230)
                Divider1(vertical: true)
                ScrollView { settings.padding(Theme.Space.l) }
                Divider1(vertical: true)
                previewColumn.frame(width: 210)
            }
            Divider1()
            footer
        }
    }

    private var presetList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                let options = [ExportPreset.matching(editor.project.canvas)] + ExportPreset.builtIn.filter { $0.id != ExportPreset.matching(editor.project.canvas).id }
                ForEach(options) { option in
                    let selected = option.id == preset.id
                    let fits = abs(Double(option.width) / Double(option.height) - canvasAspect) < 0.01
                    Button {
                        var chosen = option
                        if chosen.id != "custom", fits { chosen.frameRate = editor.project.canvas.frameRate }
                        preset = chosen
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(option.name).font(.system(size: 12, weight: .medium)).foregroundStyle(selected ? Theme.accent : Theme.text)
                                Spacer()
                                if !fits { Image(systemName: "rectangle.dashed").font(.system(size: 9)).foregroundStyle(Theme.tertiary).help("Different shape from the canvas: the video will be letterboxed") }
                            }
                            Text(verbatim: "\(option.width)×\(option.height) · \(option.codec.displayName)").font(Theme.Font.small).foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(selected ? Theme.accentSoft : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Space.s)
        }
        .background(Theme.panel)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if editor.exportLock.isLocked {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Label("Export is locked until QA passes", systemImage: "lock.fill").font(Theme.Font.sectionTitle).foregroundStyle(Theme.warning)
                    ForEach(editor.exportLock.reasons, id: \.self) { Text($0).font(Theme.Font.label).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true) }
                    Button("Open the QA Gate") { dismiss(); app.go(.comic) }.buttonStyle(.kirieCompact).padding(.top, 2)
                }
                .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.warningSoft))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.warning.opacity(0.6)))
            }
            group("Video") {
                PropertyRow(label: "Resolution") { Text(verbatim: "\(preset.width) × \(preset.height)").font(Theme.Font.mono).foregroundStyle(Theme.text) }
                PropertyRow(label: "Frame rate") {
                    Picker("Frame rate", selection: $preset.frameRate) { ForEach(FrameRate.common, id: \.self) { Text("\($0.description) fps").tag($0) } }.labelsHidden().controlSize(.small).frame(width: 110)
                }
                PropertyRow(label: "Codec") {
                    Picker("Codec", selection: Binding(get: { preset.codec }, set: { codec in
                        preset.codec = codec
                        preset.container = codec == .proRes422 ? .mov : .mp4
                    })) {
                        ForEach(VideoCodec.allCases, id: \.self) { Text($0.displayName + (Exporter.encoderAvailable($0) ? "" : " (unavailable)")).tag($0) }
                    }
                    .labelsHidden().controlSize(.small).frame(width: 170)
                }
                if preset.codec != .proRes422 {
                    PropertySlider(label: "Bitrate", value: Binding(get: { Double(preset.videoBitrate) / 1_000_000 }, set: { preset.videoBitrate = Int($0 * 1_000_000) }),
                                   range: 1...80, format: "%.0f", unit: "M")
                } else {
                    Text("ProRes 422 is a large, edit-friendly master in a .mov file. It has no alpha channel.").font(Theme.Font.small).foregroundStyle(Theme.tertiary)
                }
                PropertyRow(label: "Colour") { Text("Rec. 709 (SDR)").font(Theme.Font.label).foregroundStyle(Theme.secondary) }
            }
            group("Audio") {
                Toggle("Silent export (no audio)", isOn: $silent).toggleStyle(.checkbox).font(Theme.Font.label)
                if !silent {
                    PropertyRow(label: "Format") { Text("AAC · \(preset.audio.bitrate / 1000) kbps · 48 kHz stereo").font(Theme.Font.label).foregroundStyle(Theme.secondary) }
                }
                if !withheld.isEmpty {
                    Label("\(withheld.map(\.name).joined(separator: ", ")) \(withheld.count == 1 ? "is" : "are") marked as commercial music, so \(withheld.count == 1 ? "it is" : "they are") left out. Kirie writes a song note next to the file so you can add the track when you post.",
                          systemImage: "music.note.list").font(Theme.Font.small).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
            group("Range") {
                Picker("Range", selection: $wholeTimeline) {
                    Text("Whole timeline").tag(true)
                    Text("Part of it").tag(false)
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 220)
                if !wholeTimeline {
                    HStack(spacing: Theme.Space.s) {
                        Text("From").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                        KirieField(placeholder: "0", text: $rangeStart).frame(width: 70)
                        Text("to").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                        KirieField(placeholder: "end", text: $rangeEnd).frame(width: 70)
                        Text("seconds").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                        Button("From playhead") { rangeStart = String(format: "%.2f", editor.playhead.seconds) }.buttonStyle(.kirieCompact)
                    }
                }
                Toggle("Replace motion-heavy transitions with dissolves", isOn: $reduceMotion).toggleStyle(.checkbox).font(Theme.Font.label)
            }
            group("Save to") {
                KirieField(placeholder: "File name", text: $fileName)
                HStack {
                    Image(systemName: "folder").foregroundStyle(Theme.secondary)
                    Text((destination ?? editor.session.package.exportsURL).path).font(Theme.Font.small).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK { destination = panel.url }
                    }
                    .buttonStyle(.kirieCompact)
                }
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title.uppercased()).font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.secondary)
            content()
        }
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("OUTPUT").font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.secondary)
            ZStack {
                Color.black
                if let preview { Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit) } else { ProgressView().controlSize(.small) }
            }
            .aspectRatio(CGFloat(preset.width) / CGFloat(preset.height), contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 250)
            .overlay(Rectangle().strokeBorder(Theme.border))
            if letterboxed { Label("Letterboxed: this preset is a different shape from the canvas.", systemImage: "rectangle.dashed").font(Theme.Font.small).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true) }
            VStack(alignment: .leading, spacing: 3) {
                info("Length", formatDuration(duration.seconds) + String(format: " (%.2f s)", duration.seconds))
                info("Frames", "\(Int((duration.seconds * preset.frameRate.fps).rounded()))")
                info("Size", "about \(formatBytes(preset.estimatedFileSize(duration: duration, hasAudio: hasAudio)))")
                info("Audio", hasAudio ? "Included" : "None")
                info("Watermark", "Never")
            }
            Spacer()
        }
        .padding(Theme.Space.m)
        .background(Theme.panel)
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.Font.small).foregroundStyle(Theme.tertiary).frame(width: 62, alignment: .leading)
            Text(value).font(Theme.Font.small).foregroundStyle(Theme.text)
        }
    }

    private var footer: some View {
        HStack {
            if let first = problems.first, !editor.exportLock.isLocked {
                Label(first, systemImage: "exclamationmark.triangle").font(Theme.Font.label).foregroundStyle(Theme.warning).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.kirie).keyboardShortcut(.cancelAction)
            Button("Export") {
                if editor.project.exportPresetID != preset.id, preset.id == "custom" || ExportPreset.named(preset.id) != nil {
                    editor.perform(.setExportPreset(presetID: preset.id), reload: false)
                }
                job = app.startExport(from: editor, preset: preset, destination: outputURL, range: range,
                                      options: RenderOptions(reduceMotion: reduceMotion, silent: silent))
            }
            .buttonStyle(.kiriePrimary).keyboardShortcut(.defaultAction)
            .disabled(!problems.isEmpty || editor.exportLock.isLocked)
        }
        .padding(.horizontal, Theme.Space.xl).frame(height: 56)
    }

    /// Renders the frame under the playhead at the preset's shape, so the preview is the real output.
    private func renderPreview() {
        guard editor.sequence.duration.isPositive else { return }
        let scale = 360.0 / Double(max(preset.width, preset.height))
        func even(_ value: Double) -> Double { max(2, (value / 2).rounded() * 2) }
        let size = CGSize(width: even(Double(preset.width) * scale), height: even(Double(preset.height) * scale))
        let session = editor.session
        let time = RationalTime.min(editor.playhead, editor.sequence.duration - editor.frameRate.frameDuration).floored(toFrame: editor.frameRate)
        let presetID = preset.id
        Task {
            guard let built = try? await session.buildComposition(outputSize: size), let image = try? await Exporter.still(built: built, at: RationalTime.max(.zero, time)) else { return }
            if presetID == preset.id { preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
        }
    }
}

struct ExportProgressView: View {
    let job: ExportJob
    let editor: EditorModel
    let another: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            switch job.state {
            case .running:
                ProgressView(value: job.progress).frame(width: 380)
                Text(job.stage).font(Theme.Font.sectionTitle).foregroundStyle(Theme.text)
                Text("\(job.destination.lastPathComponent) · \(job.preset.name)").font(Theme.Font.label).foregroundStyle(Theme.secondary)
                Text("You can keep editing. The export continues in the Export Queue.").font(Theme.Font.small).foregroundStyle(Theme.tertiary)
                HStack {
                    Button("Cancel export") { job.cancellation.cancel() }.buttonStyle(.kirie)
                    Button("Keep editing") { close() }.buttonStyle(.kiriePrimary)
                }
            case .finished(let report):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(Theme.success)
                Text("Export finished").font(Theme.Font.workspaceTitle).foregroundStyle(Theme.text)
                Text("\(job.destination.lastPathComponent) · \(formatBytes(report.fileSize)) · \(String(format: "%.1f", report.elapsedSeconds)) s").font(Theme.Font.body).foregroundStyle(Theme.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("VERIFIED BY REOPENING THE FILE").font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.tertiary)
                    ForEach(report.verification.checks, id: \.name) { check in
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: check.passed ? "checkmark" : "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(check.passed ? Theme.success : Theme.danger).frame(width: 12)
                            Text(check.name.capitalized).font(Theme.Font.label).foregroundStyle(Theme.secondary).frame(width: 80, alignment: .leading)
                            Text(check.actual).font(Theme.Font.mono).foregroundStyle(Theme.text)
                        }
                    }
                }
                .padding(Theme.Space.m).background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.panel))
                if let note = report.songNotePath {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: note)) } label: {
                        Label("Exported without \(report.withheldAudio.joined(separator: ", ")). Open the song note.", systemImage: "music.note.list")
                    }
                    .buttonStyle(.kirieQuiet).foregroundStyle(Theme.warning)
                }
                HStack {
                    Button("Open file") { NSWorkspace.shared.open(job.destination) }.buttonStyle(.kirie)
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.destination]) }.buttonStyle(.kirie)
                    Button("Export another version") { another() }.buttonStyle(.kirie)
                    Button("Done") { close() }.buttonStyle(.kiriePrimary).keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                Image(systemName: "xmark.octagon.fill").font(.system(size: 34)).foregroundStyle(Theme.danger)
                Text("Export failed").font(Theme.Font.workspaceTitle).foregroundStyle(Theme.text)
                Text(message).font(Theme.Font.body).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                Text("No file was written and your project is unchanged.").font(Theme.Font.small).foregroundStyle(Theme.tertiary)
                HStack {
                    Button("Change settings") { another() }.buttonStyle(.kirie)
                    Button("Close") { close() }.buttonStyle(.kiriePrimary)
                }
            case .cancelled:
                Image(systemName: "stop.circle").font(.system(size: 34)).foregroundStyle(Theme.secondary)
                Text("Export cancelled").font(Theme.Font.workspaceTitle).foregroundStyle(Theme.text)
                Text("The partial file was removed.").font(Theme.Font.body).foregroundStyle(Theme.secondary)
                HStack {
                    Button("Change settings") { another() }.buttonStyle(.kirie)
                    Button("Close") { close() }.buttonStyle(.kiriePrimary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.xl)
    }
}

struct ExportQueueView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Text("Export Queue").font(Theme.Font.workspaceTitle).foregroundStyle(Theme.text)
                Spacer()
                Button("Clear finished") { app.clearFinishedExports() }.buttonStyle(.kirie).disabled(!app.exportJobs.contains { $0.state != .running })
            }
            if app.exportJobs.isEmpty {
                EmptyState(symbol: "square.and.arrow.up.on.square", title: "No exports yet",
                           message: "Exports run here in the background while you keep editing. Start one with Export in the toolbar (⌘E).",
                           actionTitle: app.editor == nil ? nil : "Export…", action: app.editor == nil ? nil : { app.editor?.showExport = true })
            } else {
                ScrollView {
                    VStack(spacing: Theme.Space.s) { ForEach(app.exportJobs) { ExportJobRow(job: $0) } }
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct ExportJobRow: View {
    let job: ExportJob

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Group {
                switch job.state {
                case .running: ProgressView().controlSize(.small)
                case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                case .cancelled: Image(systemName: "stop.circle").foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.destination.lastPathComponent).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(job.projectName) · \(job.timelineName) · \(job.preset.name)").font(Theme.Font.small).foregroundStyle(Theme.secondary)
                switch job.state {
                case .running: ProgressView(value: job.progress).controlSize(.small)
                case .finished(let report): Text("\(formatBytes(report.fileSize)) · verified · \(String(format: "%.1f s", report.elapsedSeconds))").font(Theme.Font.small).foregroundStyle(Theme.tertiary)
                case .failed(let message): Text(message).font(Theme.Font.small).foregroundStyle(Theme.danger).lineLimit(2)
                case .cancelled: Text("Cancelled. The partial file was removed.").font(Theme.Font.small).foregroundStyle(Theme.tertiary)
                }
            }
            Spacer()
            switch job.state {
            case .running:
                Text(job.stage).font(Theme.Font.label).foregroundStyle(Theme.secondary)
                Button("Cancel") { job.cancellation.cancel() }.buttonStyle(.kirieCompact)
            case .finished:
                Button("Open") { NSWorkspace.shared.open(job.destination) }.buttonStyle(.kirieCompact)
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([job.destination]) }.buttonStyle(.kirieCompact)
            default:
                EmptyView()
            }
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
    }
}
