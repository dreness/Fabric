import Foundation
import Metal
import Testing
@testable import Fabric
import Satin

@Suite("Undo Fix Regression")
@MainActor
struct UndoFixRegressionTests
{
    private func context() throws -> Context
    {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm,
                       depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
    }

    private func manager() -> UndoManager
    {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    private func step(_ undoManager: UndoManager, _ edit: () -> Void)
    {
        undoManager.beginUndoGrouping()
        edit()
        undoManager.endUndoGrouping()
    }

    private func model(_ parameter: FloatParameter, in graph: Graph,
                       commit: EditCommit = .eachChange) -> ParameterObservableModel<Float>
    {
        ParameterObservableModel(label: parameter.label, get: { parameter.value },
                                 set: { parameter.value = $0 }, publisher: parameter.valuePublisher,
                                 graph: graph, undoParameter: parameter, commit: commit)
    }

    @Test("A first focused draft enables Undo and can be undone and redone without losing focus")
    func focusedDraftUndoRedoAndContinuation() throws
    {
        let graph = Graph(context: try context())
        let node = StringSplitNode(context: graph.context)
        graph.addNode(node)
        let undoManager = manager()
        graph.undoManager = undoManager
        let parameter = try #require(node.inputPort.parameter as? StringParameter)
        parameter.value = "Before"
        let field = InputFieldView(param: parameter, graph: graph)
        #expect(!graph.canUndo)

        field.vm.setEditing(true)
        field.vm.uiValue = "After"
        #expect(!undoManager.canUndo, "the edit remains a draft until flushed")
        #expect(graph.canUndo, "menu validation must see the draft")
        graph.undo()
        #expect(parameter.value == "Before")
        #expect(graph.nodes.count == 1)
        #expect(!graph.canUndo)
        graph.redo()
        #expect(parameter.value == "After")

        // Focus remains on the same field; its next edit must start a fresh draft.
        field.vm.uiValue = "Again"
        graph.undo()
        #expect(parameter.value == "After")
        graph.redo()
        #expect(parameter.value == "Again")
        field.vm.setEditing(false)
        graph.undo()
        #expect(parameter.value == "After", "ending focus must not add another step")
        graph.undo()
        #expect(parameter.value == "Before")
        #expect(!graph.canUndo)
    }

    @Test("Returning an active edit to its starting value creates no history")
    func revertedDraftIsNotUndoable() throws
    {
        let graph = Graph(context: try context())
        let node = NumberBinaryOperator(context: graph.context)
        graph.addNode(node)
        let undoManager = manager()
        graph.undoManager = undoManager
        let parameter = try #require(node.inputNumber1.parameter as? FloatParameter)
        parameter.value = 1
        let model = model(parameter, in: graph)
        model.setEditing(true)
        model.uiValue = 2
        #expect(graph.canUndo)
        model.uiValue = 1
        #expect(!graph.canUndo)
        model.setEditing(false)
        #expect(!undoManager.canUndo)
    }

    @Test("An active field draft is not committed by the pause timer")
    func activeDraftHasNoTimer() async throws
    {
        let graph = Graph(context: try context())
        let node = NumberBinaryOperator(context: graph.context)
        graph.addNode(node)
        let undoManager = manager()
        graph.undoManager = undoManager
        let parameter = try #require(node.inputNumber1.parameter as? FloatParameter)
        parameter.value = 1
        let model = model(parameter, in: graph, commit: .afterPause)
        model.uiValue = 2
        // Starting an explicit edit replaces the previously scheduled pause.
        model.setEditing(true)
        model.uiValue = 3
        try await Task.sleep(for: .milliseconds(650))
        #expect(!undoManager.canUndo)
        #expect(graph.canUndo)
        #expect(model.uiValue == 3, "the control is still alive and mirrors the draft")
        graph.undo()
        #expect(parameter.value == 1)
        #expect(!graph.canUndo)
    }

    @Test("An unfocused paused edit still commits after its delay")
    func pausedDraftStillUsesTimer() async throws
    {
        let graph = Graph(context: try context())
        let node = NumberBinaryOperator(context: graph.context)
        graph.addNode(node)
        let undoManager = manager()
        graph.undoManager = undoManager
        let parameter = try #require(node.inputNumber1.parameter as? FloatParameter)
        parameter.value = 1
        let model = model(parameter, in: graph, commit: .afterPause)
        model.uiValue = 2
        #expect(!undoManager.canUndo)
        #expect(graph.canUndo)
        // Other main-actor tests can delay the timer task's start. Wait for
        // the observable effect with a bounded deadline, rather than requiring
        // the scheduler to complete it within one narrowly timed sleep.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !undoManager.canUndo && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(undoManager.canUndo)
        #expect(model.uiValue == 2, "the control remains alive while its timer runs")
        graph.undo()
        #expect(parameter.value == 1)
        graph.redo()
        #expect(parameter.value == 2)
    }

    @Test("A stale UI baseline is rejected throughout a multi-change edit and redo")
    func liveBaselineAcrossAnEdit() throws
    {
        let graph = Graph(context: try context())
        let node = NumberBinaryOperator(context: graph.context)
        graph.addNode(node)
        let undoManager = manager()
        graph.undoManager = undoManager
        let parameter = try #require(node.inputNumber1.parameter as? FloatParameter)
        parameter.value = 1
        let model = model(parameter, in: graph)
        parameter.value = 2
        #expect(model.uiValue == 1, "the engine notification is still queued")
        #expect(node.inputNumber1.value == 2, "the live port already has the new value")
        model.setEditing(true)
        model.uiValue = 3
        model.uiValue = 4
        model.setEditing(false)
        graph.undo()
        #expect(parameter.value == 2)
        #expect(!graph.canUndo)
        graph.redo()
        #expect(parameter.value == 4)
    }

    @Test("Flushing one manager leaves another document's draft pending")
    func draftsStayWithTheirManager() throws
    {
        let firstManager = manager()
        let secondManager = manager()
        let firstCommit = PendingCommit()
        let secondCommit = PendingCommit()
        var firstCount = 0
        var secondCount = 0
        firstCommit.hold(on: firstManager) { firstCount += 1 }
        secondCommit.hold(on: secondManager) { secondCount += 1 }
        PendingCommit.commitAll(on: firstManager)
        #expect(firstCount == 1)
        #expect(secondCount == 0)
        #expect(!PendingCommit.hasCommits(on: firstManager))
        #expect(PendingCommit.hasCommits(on: secondManager))
        PendingCommit.commitAll(on: secondManager)
        #expect(secondCount == 1)
    }

    @Test("Cancelling or releasing a held draft removes it from undo availability")
    func cancelledAndReleasedDraftsDoNotCount()
    {
        let undoManager = manager()
        let cancelled = PendingCommit()
        var commitCount = 0
        cancelled.hold(on: undoManager) { commitCount += 1 }
        cancelled.cancel()
        #expect(!PendingCommit.hasCommits(on: undoManager))
        do {
            let released = PendingCommit()
            released.hold(on: undoManager) { commitCount += 1 }
            #expect(PendingCommit.hasCommits(on: undoManager))
        }
        #expect(!PendingCommit.hasCommits(on: undoManager))
        PendingCommit.commitAll(on: undoManager)
        #expect(commitCount == 0)
    }

    @Test("An empty layout preserves an existing redo operation")
    func emptyLayoutPreservesRedo() throws
    {
        let graph = Graph(context: try context())
        let undoManager = manager()
        graph.undoManager = undoManager
        let note = Note(note: "Existing edit", rect: .zero)
        step(undoManager) { graph.addNote(note) }
        graph.undo()
        #expect(undoManager.canRedo)
        graph.autoLayout()
        #expect(!undoManager.canUndo)
        #expect(undoManager.canRedo)
        #expect(undoManager.redoActionName == "Add Note")
        graph.redo()
        #expect(graph.notes.map(\.id) == [note.id])
    }

    @Test("An already laid out graph produces no additional undo step")
    func unchangedLayoutHasNoUndoStep() throws
    {
        let graph = Graph(context: try context())
        let node = NumberBinaryOperator(context: graph.context)
        graph.addNode(node)
        graph.autoLayout()
        let offset = node.offset
        let undoManager = manager()
        graph.undoManager = undoManager
        graph.autoLayout()
        #expect(node.offset == offset)
        #expect(!undoManager.canUndo)
    }

    @Test("A real layout change keeps its name and positions through undo and redo")
    func actualLayoutRemainsUndoable() throws
    {
        let graph = Graph(context: try context())
        let node = NumberBinaryOperator(context: graph.context)
        graph.addNode(node)
        node.offset = CGSize(width: 333, height: 222)
        let original = node.offset
        let expected = try #require(GraphAutoLayout.compute(graph: graph).first).1
        #expect(original != expected)
        let undoManager = manager()
        graph.undoManager = undoManager
        graph.autoLayout()
        #expect(node.offset == expected)
        #expect(undoManager.undoActionName == "Auto Layout")
        for _ in 0..<2 {
            graph.undo()
            #expect(node.offset == original)
            #expect(undoManager.redoActionName == "Auto Layout")
            graph.redo()
            #expect(node.offset == expected)
            #expect(undoManager.undoActionName == "Auto Layout")
        }
    }
}
