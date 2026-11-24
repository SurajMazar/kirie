import AppKit
import SwiftUI

/// Compact icon-only button with a tooltip and an accessibility label.
struct IconButton: View {
    let symbol: String
    let label: String
    var active = false
    var size: CGFloat = Theme.Size.control
    var shortcutHint: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Theme.Size.icon, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Theme.text)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(active ? Theme.accentSoft : hovering && enabled ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.38)
        .onHover { hovering = $0 }
        .help(shortcutHint.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
    }
}

/// Primary and secondary push buttons.
struct KirieButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .secondary
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, compact ? Theme.Space.s : Theme.Space.m)
            .frame(height: compact ? Theme.Size.controlCompact : Theme.Size.control)
            .foregroundStyle(kind == .primary ? Theme.onAccent : Theme.text)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(fill(pressed: configuration.isPressed)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(kind == .secondary ? Theme.border : .clear))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }

    private func fill(pressed: Bool) -> Color {
        switch kind {
        case .primary: Theme.accent.opacity(pressed ? 0.8 : 1)
        case .secondary: pressed ? Theme.hover : Theme.elevated
        case .quiet: pressed ? Theme.hover : .clear
        }
    }
}

extension ButtonStyle where Self == KirieButtonStyle {
    static var kiriePrimary: KirieButtonStyle { KirieButtonStyle(kind: .primary) }
    static var kirie: KirieButtonStyle { KirieButtonStyle(kind: .secondary) }
    static var kirieQuiet: KirieButtonStyle { KirieButtonStyle(kind: .quiet) }
    static var kirieCompact: KirieButtonStyle { KirieButtonStyle(kind: .secondary, compact: true) }
}

/// Collapsible inspector group. Collapse state is remembered per title.
struct InspectorSection<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder var content: () -> Content
    @AppStorage private var expanded: Bool

    init(_ title: String, expandedByDefault: Bool = true, trailing: AnyView? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
        _expanded = AppStorage(wrappedValue: expandedByDefault, "inspector.section.\(title)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                Button {
                    withAnimation(.easeOut(duration: Theme.Motion.quick)) { expanded.toggle() }
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(Theme.tertiary).frame(width: 10)
                        Text(title.uppercased()).font(Theme.Font.panelHeading).kerning(0.5).foregroundStyle(Theme.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(expanded ? "expanded" : "collapsed")")
                if let trailing { trailing }
            }
            .frame(height: 30)
            .padding(.horizontal, Theme.Space.m)
            if expanded {
                VStack(alignment: .leading, spacing: Theme.Space.s) { content() }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, Theme.Space.m)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}

/// A labelled slider with a numeric field beside it, for precise entry.
struct PropertySlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var format: String = "%.2f"
    var unit: String = ""
    /// Multiplier between the stored value and what is shown (100 for percentages).
    var displayScale: Double = 1
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.secondary).frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .controlSize(.mini)
                .accessibilityLabel(label)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Font.mono)
                .multilineTextAlignment(.trailing)
                .frame(width: 46, height: Theme.Size.controlCompact)
                .padding(.horizontal, Theme.Space.xs)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(focused ? Theme.accent : Theme.border))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .accessibilityLabel("\(label) value")
            if !unit.isEmpty { Text(unit).font(Theme.Font.small).foregroundStyle(Theme.tertiary).frame(width: 12, alignment: .leading) }
        }
        .onAppear { text = String(format: format, value * displayScale) }
        .onChange(of: value) { _, new in if !focused { text = String(format: format, new * displayScale) } }
    }

    private func commit() {
        if let parsed = Double(text.replacingOccurrences(of: ",", with: ".")) {
            let clamped = min(max(parsed / displayScale, range.lowerBound), range.upperBound)
            if clamped != value {
                onEditingChanged(true)
                value = clamped
                onEditingChanged(false)
            }
        }
        text = String(format: format, value * displayScale)
    }
}

/// A row with a leading label and any control.
struct PropertyRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.secondary).frame(width: 64, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(minHeight: Theme.Size.controlCompact)
    }
}

/// What to show when a place has nothing in it yet: what it is for and the next step.
struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Theme.tertiary)
            Text(title).font(Theme.Font.sectionTitle).foregroundStyle(Theme.text)
            Text(message).font(Theme.Font.body).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.kirie).padding(.top, Theme.Space.xs)
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Small pill for states such as "Saved", "PASS" or "Planned".
struct StatusBadge: View {
    let text: String
    var symbol: String?
    var tint: Color = Theme.secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule().fill(tint.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }
}

/// Marks a capability that is designed but not built yet, instead of showing an inert control.
struct PlannedNote: View {
    let text: String
    var phase = "Phase 2"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            StatusBadge(text: phase, symbol: "clock", tint: Theme.tertiary)
            Text(text).font(Theme.Font.small).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Not available yet. \(text) Planned for \(phase).")
    }
}

struct PanelHeader: View {
    let title: String
    var trailing: AnyView?

    var body: some View {
        HStack {
            Text(title).font(Theme.Font.sectionTitle).foregroundStyle(Theme.text)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 36)
    }
}

struct Divider1: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Theme.border).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Non-blocking notification shown at the bottom of the window.
struct Toast: Identifiable, Equatable {
    enum Kind { case info, success, warning, error }
    let id = UUID()
    var kind: Kind
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(toast.message).font(Theme.Font.body).foregroundStyle(Theme.text).lineLimit(3)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) { action(); dismiss() }.buttonStyle(.kirieCompact)
            }
            IconButton(symbol: "xmark", label: "Dismiss", size: 20, action: dismiss)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.borderStrong))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch toast.kind {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private var tint: Color {
        switch toast.kind {
        case .info: Theme.secondary
        case .success: Theme.success
        case .warning: Theme.warning
        case .error: Theme.danger
        }
    }
}

/// Text field in Kirie's compact inset style.
struct KirieField: View {
    let placeholder: String
    @Binding var text: String
    var onCommit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.Font.body)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: Theme.Size.control)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.inset))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(focused ? Theme.accent : Theme.border))
            .focused($focused)
            .onSubmit(onCommit)
            .onChange(of: focused) { _, isFocused in if !isFocused { onCommit() } }
    }
}

extension View {
    func panelBackground() -> some View { background(Theme.panel) }

    /// Animations that respect Reduce Motion.
    func kirieAnimation<V: Equatable>(_ value: V, reduceMotion: Bool) -> some View {
        animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.standard), value: value)
    }
}

func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
