from pathlib import Path
root=Path('/Users/andre/.codex/worktrees')
p=root/'review-pr406/Fabric/Tests/CopilotUndoResponseTests.swift'
p.write_text('''import Foundation
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
''')
p=root/'review-pr411/Fabric/Tests/CopilotUUIDResponseTests.swift'
p.write_text('''import Foundation
import Testing
@testable import Fabric

@Suite("Copilot UUID Response")
struct CopilotUUIDResponseTests {
    @Test("An identity container does not turn nested user fields into identities")
    func nestedIdentityContainer() throws {
        let original = UUID().uuidString
        let replacement = UUID().uuidString
        let object: [String: Any] = ["nodeIDs": [["id": original, "value": original, "text": [original]]]]
        let result = try #require(Graph.remapUUIDs(in: object, remap: [original: replacement]) as? [String: Any])
        let members = try #require(result["nodeIDs"] as? [[String: Any]])
        let member = try #require(members.first)
        #expect(member["id"] as? String == replacement)
        #expect(member["value"] as? String == original)
        #expect(member["text"] as? [String] == [original])
    }
}
''')
