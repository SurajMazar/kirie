import Foundation

/// Owns the project value and the undo/redo history. The single entry point for edits.
///
/// Memory policy: history keeps at most `historyLimit` entries (default 300). Each entry stores the
/// before and after values of only the top-level components that changed (usually one timeline),
/// so a long session costs roughly `entries × timeline size`.
public struct CommandEngine: Sendable {
    public private(set) var project: Project
    public private(set) var undoStack: [HistoryEntry] = []
    public private(set) var redoStack: [HistoryEntry] = []
    /// Increments on every state change, including undo and redo. Used to schedule autosave.
    public private(set) var revision: Int = 0
    public var historyLimit: Int = 300

    public init(project: Project) {
        self.project = project
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }

    /// Replaces the project wholesale (open, restore snapshot). Clears history.
    public mutating func load(_ project: Project) {
        self.project = project
        undoStack.removeAll()
        redoStack.removeAll()
        revision += 1
    }

    /// Validates and applies one command.
    @discardableResult
    public mutating func execute(_ command: EditCommand, actor: CommandActor = .user, id: UUID = UUID(),
                                 timestamp: Date = Date(), coalesceKey: String? = nil) throws -> CommandOutcome {
        try execute([command], label: nil, actor: actor, id: id, timestamp: timestamp, coalesceKey: coalesceKey)
    }

    /// Applies several commands as one undo step. If any command fails, nothing changes.
    @discardableResult
    public mutating func execute(_ commands: [EditCommand], label: String?, actor: CommandActor = .user, id: UUID = UUID(),
                                 timestamp: Date = Date(), coalesceKey: String? = nil) throws -> CommandOutcome {
        guard !commands.isEmpty else { throw EditError.invalid("No command to run.") }
        var applier = CommandApplier(project: project)
        var summaries: [String] = []
        for (index, command) in commands.enumerated() {
            summaries.append(try applier.apply(command))
            // Re-laying out the timeline costs time proportional to its size, so in a batch it is
            // skipped when the next command does not read clip positions (for example a run of
            // imports or appends). The final state is always settled.
            let next = index + 1 < commands.count ? commands[index + 1] : nil
            if next?.readsLayout ?? true { applier.settle() }
        }
        var next = applier.project
        next.modifiedAt = timestamp.roundedToMilliseconds
        let problems = ProjectValidator.validate(next).filter { $0.severity == .error }
        guard problems.isEmpty else { throw EditError.validationFailed(problems.map(\.message)) }

        let redo = ProjectPatch.diff(from: project, to: next)
        let undo = ProjectPatch.diff(from: next, to: project)
        let envelope = CommandEnvelope(id: id, timestamp: timestamp, actor: actor,
                                       label: label ?? summaries.last ?? "Edit", commands: commands)
        var entry = HistoryEntry(envelope: envelope, undo: undo, redo: redo, coalesceKey: coalesceKey)
        project = next
        revision += 1

        if redo.isEmpty {
            // Nothing actually changed: do not pollute history.
            return CommandOutcome(entry: entry, events: [])
        }
        if let coalesceKey, let last = undoStack.last, last.coalesceKey == coalesceKey {
            // Continuous gesture (a slider drag): keep the original "before", take the newest "after".
            entry.undo = last.undo
            undoStack[undoStack.count - 1] = entry
        } else {
            undoStack.append(entry)
            if undoStack.count > historyLimit { undoStack.removeFirst(undoStack.count - historyLimit) }
        }
        redoStack.removeAll()
        return CommandOutcome(entry: entry, events: redo.events)
    }

    /// Checks whether a command would succeed without changing anything.
    public func dryRun(_ commands: [EditCommand]) throws -> ProjectPatch {
        var copy = self
        let outcome = try copy.execute(commands, label: nil)
        return outcome.entry.redo
    }

    @discardableResult
    public mutating func undo() throws -> CommandOutcome {
        guard let entry = undoStack.popLast() else { throw EditError.nothingToUndo }
        entry.undo.apply(to: &project)
        redoStack.append(entry)
        revision += 1
        return CommandOutcome(entry: entry, events: entry.undo.events)
    }

    @discardableResult
    public mutating func redo() throws -> CommandOutcome {
        guard let entry = redoStack.popLast() else { throw EditError.nothingToRedo }
        entry.redo.apply(to: &project)
        undoStack.append(entry)
        revision += 1
        return CommandOutcome(entry: entry, events: entry.redo.events)
    }

    /// Ends a coalescing run so the next command starts a fresh undo step.
    public mutating func breakCoalescing() {
        guard let last = undoStack.indices.last else { return }
        undoStack[last].coalesceKey = nil
    }
}
