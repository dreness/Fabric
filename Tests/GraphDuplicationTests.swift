import Foundation
import Metal
import Testing
@testable import Fabric
import Satin

/// Duplicating gives a copy new ids and leaves its values as they are.
@Suite("Graph Duplication")
struct GraphDuplicationTests
{
    private func makeContext() -> Context?
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return Context(device: device,
                       sampleCount: 1,
                       colorPixelFormat: .bgra8Unorm,
                       depthPixelFormat: .depth32Float,
                       stencilPixelFormat: .invalid)
    }

    @Test("Duplicating a node leaves a UUID-shaped string value as it is")
    func duplicateKeepsUUIDShapedValues() throws
    {
        guard let context = makeContext() else { return }
        let graph = Graph(context: context)
        let node = StringLengthNode(context: context)
        graph.addNode(node)
        let text = UUID().uuidString
        node.inputPort.value = text

        let copy = try #require(graph.duplicateNodes([node]).first as? StringLengthNode)
        #expect(copy.id != node.id)
        #expect(copy.inputPort.id != node.inputPort.id)
        #expect(copy.inputPort.value == text)
    }

    @Test("Duplicating preserves strings that match a node or port ID")
    func duplicateKeepsNodeAndPortIDStrings() throws
    {
        guard let context = makeContext() else { return }
        let graph = Graph(context: context)
        let node = StringLengthNode(context: context)
        graph.addNode(node)

        let portIDText = node.inputPort.id.uuidString
        let nodeIDText = node.id.uuidString
        node.inputPort.value = portIDText
        node.userName = nodeIDText

        let copy = try #require(graph.duplicateNodes([node]).first as? StringLengthNode)
        #expect(copy.inputPort.value == portIDText)
        #expect(copy.userName == nodeIDText)
    }

    @Test("UUID remapping rewrites identity fields but leaves user text and ordinary value arrays alone")
    func remapUUIDsOnlyChangesIdentityFields() throws
    {
        let uuid = UUID().uuidString
        let sibling = UUID().uuidString
        let remapped = Graph.remapUUIDs(in: [
            "id": uuid,
            "innerPortID": sibling,
            "text": uuid,
            "identityIDs": [uuid, sibling],
            "valueArray": [uuid, "hello"],
            "preserved": uuid,
        ], remap: [uuid: "remapped-uuid", sibling: "remapped-sibling"], preservingKeys: ["preserved"]) as? [String: Any]

        let remappedID = try #require(remapped?["id"] as? String)
        let remappedInnerID = try #require(remapped?["innerPortID"] as? String)
        let remappedText = try #require(remapped?["text"] as? String)
        let remappedIDs = try #require(remapped?["identityIDs"] as? [String])
        let valueArray = try #require(remapped?["valueArray"] as? [String])

        #expect(remappedID == "remapped-uuid")
        #expect(remappedInnerID == "remapped-sibling")
        #expect(remappedText == uuid)
        #expect(remappedIDs == ["remapped-uuid", "remapped-sibling"])
        #expect(valueArray == [uuid, "hello"])
        #expect(remapped?["preserved"] as? String == uuid)
    }
}
