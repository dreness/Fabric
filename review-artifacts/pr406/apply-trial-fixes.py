from pathlib import Path

root = Path('/Users/andre/.codex/worktrees/review-pr406/Fabric')

def replace(relative_path, before, after):
    path = root / relative_path
    source = path.read_text()
    assert source.count(before) == 1, (relative_path, before)
    path.write_text(source.replace(before, after))

replace('Fabric/Views/PendingCommit.swift',
'''    /// Holds `commit` for `delay`, replacing any commit held. `undoManager` is
    /// the one the commit records on.
    func schedule(after delay: Duration, undoManager: UndoManager?, _ commit: @escaping () -> Void)
    {
        self.cancel()
        self.commit = commit
        self.timer = Task''',
'''    /// Holds an active edit until editing ends or Graph.undo()/redo() flushes
    /// it. Unlike a paused edit, an active edit has no timer.
    func hold(on undoManager: UndoManager?, _ commit: @escaping () -> Void)
    {
        self.cancel()
        self.commit = commit
        if let undoManager { Self.register(self, on: undoManager) }
    }

    /// Holds `commit` for `delay`, replacing any commit held. `undoManager` is
    /// the one the commit records on.
    func schedule(after delay: Duration, undoManager: UndoManager?, _ commit: @escaping () -> Void)
    {
        self.hold(on: undoManager, commit)
        self.timer = Task''')

replace('Fabric/Views/PendingCommit.swift',
'''            self?.flush()
        }
        if let undoManager { Self.register(self, on: undoManager) }
''',
'''            self?.flush()
        }
''')

replace('Fabric/Views/PendingCommit.swift',
'''    /// Commits now every commit held for `undoManager`.
''',
'''    /// Whether this manager has an uncommitted edit, even when its undo
    /// history is empty. Cancelled and released commits do not count.
    static func hasCommits(on undoManager: UndoManager) -> Bool
    {
        self.registry[ObjectIdentifier(undoManager), default: []].contains {
            $0.pendingCommit?.commit != nil
        }
    }

    /// Commits now every commit held for `undoManager`.
''')

replace('Fabric/Views/Parameters/ParameterObservableModel.swift',
'''                if editStart == nil { editStart = oldValue }''',
'''                // The parameter is authoritative; its queued notification
                // may not have reached the UI mirror yet.
                if editStart == nil { editStart = getValue() }''')

replace('Fabric/Views/Parameters/ParameterObservableModel.swift',
'''        isEditing = editing
        if !editing { self.commitEdit() }
''',
'''        isEditing = editing
        if editing {
            if editStart != nil { self.commitUnlessEditing() }
        } else {
            self.commitEdit()
        }
''')

replace('Fabric/Views/Parameters/ParameterObservableModel.swift',
'''        guard !isEditing else { return }
        switch commit
''',
'''        // A gesture that returns to its starting value is not an edit.
        guard undoParameter != nil, editStart != getValue() else {
            editStart = nil
            pendingCommit.cancel()
            return
        }
        if isEditing {
            pendingCommit.hold(on: graph?.effectiveUndoManager) { [weak self] in
                self?.commitEdit()
            }
            return
        }
        switch commit
''')

replace('Fabric/Graph/Graph.swift',
'''    public var canUndo: Bool { self.effectiveUndoManager?.canUndo ?? false }''',
'''    public var canUndo: Bool
    {
        guard let undoManager = self.effectiveUndoManager else { return false }
        return PendingCommit.hasCommits(on: undoManager) || undoManager.canUndo
    }''')

replace('Fabric/Graph/GraphAutoLayout.swift',
'''        let layout = GraphAutoLayout.compute(graph: self)

        self.performEdit''',
'''        let layout = GraphAutoLayout.compute(graph: self).filter { node, offset in
            node.offset != offset
        }
        guard !layout.isEmpty else { return }

        self.performEdit''')
