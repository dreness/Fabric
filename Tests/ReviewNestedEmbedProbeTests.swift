import Foundation
import Metal
import Testing
@testable import Fabric
import Satin

/// Create Subgraph inside a sub graph, moving a node whose published output's
/// proxy is wired in the graph above. Prints EMBEDPROBE lines; PR API.
@Suite("Review nested embed probe")
@MainActor
struct ReviewNestedEmbedProbeTests
{
    @Test func nestedEmbedKeepsParentWire() throws
    {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm,
                              depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
        let graph = Graph(context: context)
        let owner = SubgraphNode(context: context)
        let neighbour = NumberBinaryOperator(context: context)
        let movedNode = NumberBinaryOperator(context: context)
        graph.addNode(owner)
        owner.subGraph.addNode(neighbour)
        owner.subGraph.addNode(movedNode)

        let port = movedNode.outputNumber
        owner.subGraph.setPublished(true, on: port)
        let proxy = try #require(owner.ports.first { $0.id == port.id })
        let downstream = NumberBinaryOperator(context: context)
        graph.addNode(downstream)
        _ = try #require(graph.connect(proxy, to: downstream.inputNumber1))

        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        graph.undoManager = undoManager
        owner.subGraph.undoManager = undoManager

        func report(_ stage: String)
        {
            let ownerProxy = owner.ports.first { $0.id == port.id }
            let wired = downstream.inputNumber1.connections.first?.outletPort
            print("EMBEDPROBE tree=\(ProcessInfo.processInfo.environment["FABRIC_TREE"] ?? "?") stage=\(stage) ownerHasProxy=\(ownerProxy != nil) parentConnections=\(graph.connections.count) downstreamWiredToOwnerProxy=\(wired != nil && wired === ownerProxy) portPublished=\(port.published) movedNodeInOwnerGraph=\(movedNode.graph === owner.subGraph)")
        }

        report("before")
        undoManager.beginUndoGrouping()
        _ = try owner.subGraph.createSubgraph(from: [movedNode], centeredOn: movedNode, usingClass: SubgraphNode.self)
        undoManager.endUndoGrouping()
        report("afterEmbed")
        undoManager.undo()
        report("afterUndo")
    }
}
