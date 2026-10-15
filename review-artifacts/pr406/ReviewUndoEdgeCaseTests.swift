import Foundation
import Metal
import Testing
@testable import Fabric
import Satin

// Review-only probes, copied into the isolated worktree after the unmodified
// PR tests run. No production code is changed.
@Suite("Review Undo Edge Cases")
@MainActor
struct ReviewUndoEdgeCaseTests {
    private func context() throws -> Context {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These probes require actual Metal access")
        return Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm,
                       depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
    }

    private func step(_ manager: UndoManager, _ edit: () -> Void) {
        manager.beginUndoGrouping()
        edit()
        manager.endUndoGrouping()
    }

    @Test("Auto Layout on an empty graph does not create an undoable edit")
    func emptyLayoutHasNoUndoStep() throws {
        let graph = Graph(context: try context())
        let manager = UndoManager()
        manager.groupsByEvent = false
        graph.undoManager = manager
        graph.autoLayout()
        #expect(!manager.canUndo)
    }

    @Test("Graph.undo flushes a change waiting for its pause")
    func pauseIsFlushed() throws {
        let graph = Graph(context: try context())
        let node = NumberBinaryOperator(context: graph.context)
        graph.addNode(node)
        let manager = UndoManager()
        manager.groupsByEvent = false
        graph.undoManager = manager
        let parameter = try #require(node.inputNumber1.parameter as? FloatParameter)
        parameter.value = 1
        let model = ParameterObservableModel(label: "Amount", get: { parameter.value },
            set: { parameter.value = $0 }, publisher: parameter.valuePublisher,
            graph: graph, undoParameter: parameter, commit: .afterPause)
        model.uiValue = 2
        graph.undo()
        #expect(parameter.value == 1)
        graph.redo()
        #expect(parameter.value == 2)
    }

    @Test("Undo during a focused edit must undo the value before the preceding graph edit")
    func focusedEditIsFlushed() throws {
        let graph = Graph(context: try context())
        let manager = UndoManager()
        manager.groupsByEvent = false
        graph.undoManager = manager
        let node = StringSplitNode(context: graph.context)
        step(manager) { graph.addNode(node) }
        let parameter = try #require(node.inputPort.parameter as? StringParameter)
        parameter.value = "Before"
        let field = InputFieldView(param: parameter, graph: graph)
        // InputFieldComponentView sends this on focus and does not send false
        // until Return, focus loss or disappearance. A menu command need not blur it.
        field.vm.setEditing(true)
        field.vm.uiValue = "After"
        graph.undo()
        #expect(graph.nodes.contains { $0.id == node.id })
        #expect(parameter.value == "Before")
    }

    @Test("A UI edit uses the live parameter value as its undo baseline")
    func undoBaselineFollowsParameter() throws {
        let graph = Graph(context: try context())
        let node = NumberBinaryOperator(context: graph.context)
        graph.addNode(node)
        let manager = UndoManager()
        manager.groupsByEvent = false
        graph.undoManager = manager
        let parameter = try #require(node.inputNumber1.parameter as? FloatParameter)
        parameter.value = 1
        let model = ParameterObservableModel(label: "Amount", get: { parameter.value },
            set: { parameter.value = $0 }, publisher: parameter.valuePublisher,
            graph: graph, undoParameter: parameter)
        // Engine-to-UI notifications are delivered asynchronously and throttled.
        parameter.value = 2
        step(manager) { model.uiValue = 3 }
        graph.undo()
        #expect(parameter.value == 2)
    }
}
