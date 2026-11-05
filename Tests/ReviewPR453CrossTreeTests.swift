import Foundation
import Metal
import Testing
@testable import Fabric
import Satin

/// Review probes for Fabric#453 that compile on base and PR.
/// FABRIC_TREE=base writes a document with stored parameter inlets to
/// FABRIC_REVIEW_DOC; FABRIC_TREE=pr opens that file. Prints REVIEW453X lines.
@Suite("Review 453 cross-tree", .serialized)
struct ReviewPR453CrossTreeTests
{
    private var tree: String { ProcessInfo.processInfo.environment["FABRIC_TREE"] ?? "unknown" }
    private var documentPath: String? { ProcessInfo.processInfo.environment["FABRIC_REVIEW_DOC"] }

    private func makeContext() throws -> Context
    {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm)
    }

    private func decode(_ data: Data, context: Context) throws -> Graph
    {
        let decoder = JSONDecoder()
        decoder.context = DecoderContext(documentContext: context)
        return try decoder.decode(Graph.self, from: data)
    }

    @Test("Stored parameter inlets keep their values across save and open")
    func storedParameterInletValues() throws
    {
        let context = try makeContext()
        let data: Data
        var p2uID: UUID
        var u2pID: UUID

        if tree == "base"
        {
            let graph = Graph(context: context)
            let p2u = PixelsToUnitsNode(context: context)
            let u2p = UnitsoPixelsNode(context: context)
            graph.addNode(p2u)
            graph.addNode(u2p)
            p2u.inputCursorPosition.value = 640
            u2p.inputUnitPosition.value = 0.5
            data = try JSONEncoder().encode(graph)
            if let documentPath { try data.write(to: URL(fileURLWithPath: documentPath)) }
            p2uID = p2u.id
            u2pID = u2p.id
        }
        else
        {
            let path = try #require(documentPath, "FABRIC_REVIEW_DOC names the base-written document")
            data = try Data(contentsOf: URL(fileURLWithPath: path))
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let nodes = json["nodeMap"] as? [[String: Any]] ?? []
            func id(of type: String) -> UUID?
            {
                nodes.first { ($0["type"] as? String)?.hasSuffix(type) == true }
                    .flatMap { ($0["value"] as? [String: Any])?["id"] as? String }
                    .flatMap(UUID.init(uuidString:))
            }
            p2uID = try #require(id(of: "PixelsToUnitsNode"))
            u2pID = try #require(id(of: "UnitsoPixelsNode"))
        }

        let opened = try decode(data, context: context)
        let p2u = try #require(opened.node(forID: p2uID) as? PixelsToUnitsNode)
        let u2p = try #require(opened.node(forID: u2pID) as? UnitsoPixelsNode)
        print("REVIEW453X tree=\(tree) stored-value pixelsToUnits=\(String(describing: p2u.inputCursorPosition.value)) unitsToPixels=\(String(describing: u2p.inputUnitPosition.value))")
        #expect(p2u.inputCursorPosition.value == 640)
        #expect(u2p.inputUnitPosition.value == 0.5)
    }

    @Test("A duplicated subgraph's inner graph gets its own id")
    func duplicatedSubgraphInnerGraphID() throws
    {
        let context = try makeContext()
        let graph = Graph(context: context)
        let subgraph = SubgraphNode(context: context)
        graph.addNode(subgraph)
        subgraph.subGraph.addNode(NumberBinaryOperator(context: context))

        let duplicate = try #require(graph.duplicateNodes([subgraph]).first as? SubgraphNode)
        print("REVIEW453X tree=\(tree) duplicate-subgraph sameInnerID=\(duplicate.subGraph.id == subgraph.subGraph.id)")
        #expect(duplicate.subGraph.id != subgraph.subGraph.id)
    }
}
