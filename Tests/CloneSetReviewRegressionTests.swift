import Foundation
import Metal
import Testing
@testable import Fabric
import Satin

@Suite("Clone Set Review")
@MainActor
struct CloneSetReviewRegressionTests {
    private func context() throws -> Context {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm, depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
    }

    @Test("Duplicate preserves text even when it is an actual identity", arguments: [false, true])
    func duplicateIDText(portID: Bool) throws {
        let graph = Graph(context: try context())
        let node = StringLengthNode(context: graph.context)
        graph.addNode(node)
        let text = (portID ? node.inputPort.id : node.id).uuidString
        node.inputPort.value = text
        node.userName = text
        let copy = try #require(graph.duplicateNodes([node]).first as? StringLengthNode)
        #expect(copy.id != node.id)
        #expect(copy.inputPort.id != node.inputPort.id)
        #expect(copy.inputPort.value == text)
        #expect(copy.userName == text)
    }

    @Test("Remapping ids leaves text and arrays of values intact")
    func remappingSchema() throws {
        let id = UUID().uuidString
        let fresh = UUID().uuidString
        let object: [String: Any] = ["id": id, "inletPortID": id, "nodeIDs": [id], "value": id, "text": [id]]
        let result = try #require(Graph.remapUUIDs(in: object, remap: [id: fresh]) as? [String: Any])
        #expect(result["id"] as? String == fresh)
        #expect(result["inletPortID"] as? String == fresh)
        #expect(result["nodeIDs"] as? [String] == [fresh])
        #expect(result["value"] as? String == id)
        #expect(result["text"] as? [String] == [id])
    }

    @Test("A mode change carries the parked custom separator to sibling clones")
    func parkedSeparator() throws {
        let graph = Graph(context: try context())
        let manager = UndoManager()
        manager.groupsByEvent = false
        graph.undoManager = manager
        manager.beginUndoGrouping()
        let member = SubgraphNode(context: graph.context)
        graph.addNode(member)
        let split = StringSplitNode(context: graph.context)
        member.subGraph.addNode(split)
        let sibling = try graph.duplicateAsClone(member)
        let other = try #require(sibling.subGraph.node(forID: split.id) as? StringSplitNode)
        manager.endUndoGrouping()
        manager.removeAllActions()
        manager.beginUndoGrouping()
        split.inputSeparator?.value = "::"
        split.setStrategy(StringSplitMode.comma)
        manager.endUndoGrouping()
        #expect(split.customSeparator == "::")
        #expect(other.customSeparator == "::")
        #expect(sibling.isInStepWithCloneSet)
        graph.undo()
        #expect(other.splitMode == .custom)
        graph.redo()
        #expect(other.customSeparator == "::")
        let decoder = JSONDecoder()
        decoder.context = DecoderContext(documentContext: graph.context)
        let reopened = try decoder.decode(Graph.self, from: JSONEncoder().encode(graph))
        let reopenedSibling = try #require(reopened.node(forID: sibling.id) as? SubgraphNode)
        let reopenedSplit = try #require(reopenedSibling.subGraph.node(forID: split.id) as? StringSplitNode)
        #expect(reopenedSplit.customSeparator == "::")
        #expect(reopenedSibling.isInStepWithCloneSet)
        let sourceSettings = try #require(split.settings)
        #expect(other.settings?.isEqual(to: sourceSettings) == true)
    }

    @Test("String Split gives and takes the complete settings value")
    func splitSettingsRoundTrip() throws {
        let node = StringSplitNode(context: try context())
        node.inputSeparator?.value = "|"
        node.setStrategy(StringSplitMode.comma)
        let expected = try #require(node.settings)
        let copy = StringSplitNode(context: node.context)
        copy.apply(expected)
        #expect(copy.customSeparator == "|")
        #expect(copy.settings?.isEqual(to: expected) == true)
        copy.setStrategy(StringSplitMode.custom)
        #expect(copy.inputSeparator?.value == "|")
    }
    @Test("An unrelated clone edit preserves each published separator value")
    func publishedSeparatorValuesStayLocal() throws {
        let graph = Graph(context: try context())
        let member = SubgraphNode(context: graph.context)
        graph.addNode(member)
        let split = StringSplitNode(context: graph.context)
        member.subGraph.addNode(split)
        member.subGraph.setPublished(true, on: try #require(split.inputSeparator))
        let sibling = try graph.duplicateAsClone(member)
        let other = try #require(sibling.subGraph.node(forID: split.id) as? StringSplitNode)
        split.inputSeparator?.value = ":"
        other.inputSeparator?.value = "|"
        member.subGraph.addNode(NumberBinaryOperator(context: graph.context))
        graph.syncCloneSets(editedIn: member.subGraph)
        #expect(split.inputSeparator?.value == ":")
        #expect(other.inputSeparator?.value == "|")
        #expect(sibling.isInStepWithCloneSet)
    }

}
