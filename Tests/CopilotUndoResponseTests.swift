import Foundation
import Metal
import Satin
import Testing
@testable import Fabric

@Suite("Copilot Undo Response")
@MainActor
struct CopilotUndoResponseTests {
    @Test("Focus alone does not freeze the baseline before a later engine change")
    func engineChangeAfterFocus() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm,
                              depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
        let graph = Graph(context: context)
        let node = NumberBinaryOperator(context: context)
        graph.addNode(node)
        let manager = UndoManager()
        manager.groupsByEvent = false
        graph.undoManager = manager
        let parameter = try #require(node.inputNumber1.parameter as? FloatParameter)
        parameter.value = 1
        let model = ParameterObservableModel(label: "Amount", get: { parameter.value },
            set: { parameter.value = $0 }, publisher: parameter.valuePublisher,
            graph: graph, undoParameter: parameter)
        model.setEditing(true)
        parameter.value = 2
        #expect(model.uiValue == 1)
        model.uiValue = 3
        model.setEditing(false)
        graph.undo()
        #expect(parameter.value == 2)
        graph.redo()
        #expect(parameter.value == 3)
    }
}
