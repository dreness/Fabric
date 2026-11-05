import Foundation
import Metal
import Testing
@testable import Fabric
import Satin

/// DeclaredPortsTests' fixture node, reduced to a declared list of ports.
private final class ReviewDeclaredNode: Node
{
    override class var name: String { "Review Declared" }
    override class var nodeType: Node.NodeType { .Utility }

    var entries: [(String, PortType, Bool)] = []

    required init(context: Context) { super.init(context: context) }

    init(context: Context, entries: [(String, PortType, Bool)])
    {
        self.entries = entries
        super.init(context: context)
    }

    required init(from decoder: any Decoder) throws { try super.init(from: decoder) }

    override func declaredPorts() -> [PortDeclaration]
    {
        super.declaredPorts() + entries.map { PortDeclaration(key: $0.0, portType: $0.1, kind: $0.2 ? .Inlet : .Outlet, name: $0.0) }
    }
}

/// Review probes for Fabric#453. Each prints a REVIEW453 line with what it saw.
@Suite("Review 453", .serialized)
struct ReviewPR453Tests
{
    private func makeContext() throws -> Context
    {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm)
    }

    private func reopen(_ graph: Graph, context: Context) throws -> Graph
    {
        let data = try JSONEncoder().encode(graph)
        let decoder = JSONDecoder()
        decoder.context = DecoderContext(documentContext: context)
        return try decoder.decode(Graph.self, from: data)
    }

    // MARK: DeclaredPortsTests.registryReportsRetype crash

    /// The same steps as registryReportsRetype, with the node kept alive until
    /// the retired port is released and the port detached, as
    /// Node.reconcilePorts does. Passes where the original traps.
    @Test("Registry retype, with the retired port detached before the node goes")
    func registryRetypeWithRetiredPortDetached() throws
    {
        let context = try makeContext()
        let node = ReviewDeclaredNode(context: context, entries: [("a", .Float, true), ("out", .Float, false)])
        withExtendedLifetime(node) {
            let a = node.findPort(named: "a", as: Fabric.Port.self)
            let declarations = node.declaredPorts().map { declaration in
                declaration.key == .own("a") ? PortDeclaration(key: "a", portType: .Int, kind: .Inlet, name: "a") : declaration
            }
            let reconciliation = node.registry.reconcile(to: declarations, applying: [], owner: node, hydrating: nil)
            print("REVIEW453 registry-retype retyped=\(reconciliation.retyped.count) retiredStillNamesNode=\(a?.node === node)")
            #expect(reconciliation.retyped.first?.old === a)
            a?.node = nil
        }
    }

    // MARK: Stored parameter inlets in old documents

    @Test("Old Pixels to Units / Units to Pixels documents keep their stored parameter values")
    func storedParameterInletKeepsSavedValue() throws
    {
        let context = try makeContext()

        let pixelIn = LegacyDocumentFixture.SavedPort(key: "inputCursorPositionPort", type: "Float", name: "Pixel",
                                                       parameter: ("float", Float(640)), savedOutsideList: true)
        let unitOut = LegacyDocumentFixture.SavedPort(key: "outputUnitPositionPort", type: "Float", kind: "Outlet",
                                                       name: "Unit", savedOutsideList: true)
        let pixelsToUnits = LegacyDocumentFixture.SavedNode(type: "PixelsToUnitsNode", ports: [pixelIn, unitOut])

        let unitIn = LegacyDocumentFixture.SavedPort(key: "inputUnitPositionPort", type: "Float", name: "Unit",
                                                      parameter: ("float", Float(0.5)), savedOutsideList: true)
        let pixelOut = LegacyDocumentFixture.SavedPort(key: "outputCursorPositionPort", type: "Float", kind: "Outlet",
                                                        name: "Pixel", savedOutsideList: true)
        let unitsToPixels = LegacyDocumentFixture.SavedNode(type: "UnitsoPixelsNode", ports: [unitIn, pixelOut])

        let graph = try LegacyDocumentFixture(nodes: [pixelsToUnits, unitsToPixels]).decode(context: context)
        let p2u = try #require(graph.node(forID: pixelsToUnits.id) as? PixelsToUnitsNode)
        let u2p = try #require(graph.node(forID: unitsToPixels.id) as? UnitsoPixelsNode)

        print("REVIEW453 stored-value pixelsToUnits saved=640 loaded=\(String(describing: p2u.inputCursorPosition.value)) unitsToPixels saved=0.5 loaded=\(String(describing: u2p.inputUnitPosition.value)) droppedState=\(graph.droppedPortStateDiagnostics.count)")
        #expect(p2u.inputCursorPosition.value == 640)
        #expect(u2p.inputUnitPosition.value == 0.5)
    }

    // MARK: Duplicate of a subgraph

    @Test("A duplicated subgraph's inner graph gets its own id")
    func duplicatedSubgraphHasItsOwnInnerGraphID() throws
    {
        let context = try makeContext()
        let graph = Graph(context: context)
        let subgraph = SubgraphNode(context: context)
        graph.addNode(subgraph)
        subgraph.subGraph.addNode(NumberBinaryOperator(context: context))

        let duplicate = try #require(graph.duplicateNodes([subgraph]).first as? SubgraphNode)
        print("REVIEW453 duplicate-subgraph originalInner=\(subgraph.subGraph.id) duplicateInner=\(duplicate.subGraph.id) same=\(subgraph.subGraph.id == duplicate.subGraph.id)")
        #expect(duplicate.subGraph.id != subgraph.subGraph.id)
    }

    // MARK: Published order across undo

    @Test("Undo of an unpublish puts the proxy back where it was")
    func unpublishUndoKeepsProxyOrder() throws
    {
        let context = try makeContext()
        let outer = Graph(context: context)
        let subgraph = SubgraphNode(context: context)
        outer.addNode(subgraph)
        let inner = NumberBinaryOperator(context: context)
        subgraph.subGraph.addNode(inner)

        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        outer.undoManager = undoManager
        subgraph.subGraph.undoManager = undoManager

        func step(_ edit: () -> Void) { undoManager.beginUndoGrouping(); edit(); undoManager.endUndoGrouping() }
        step { subgraph.subGraph.setPublished(true, port: inner.inputNumber1, name: "A") }
        step { subgraph.subGraph.setPublished(true, port: inner.inputNumber2, name: "B") }
        func order() -> [String] { subgraph.subGraph.publishedPortEntries.map { $0.name ?? "-" } }
        func proxyNames() -> [String] { subgraph.ports.filter { $0 is any ProxyPortProtocol }.map(\.displayName) }
        let before = order()
        let proxiesBefore = proxyNames()

        step { subgraph.subGraph.setPublished(false, port: inner.inputNumber1) }
        undoManager.undo()

        print("REVIEW453 unpublish-undo published before=\(before) after=\(order()) proxies before=\(proxiesBefore) after=\(proxyNames())")
        #expect(order() == before)
        #expect(proxyNames() == proxiesBefore)
    }

    // MARK: Explicit Virtual across a save

    @Test("A wired numeric type-agnostic node set to Virtual is still Virtual after a save and reopen")
    func explicitVirtualSurvivesReopen() throws
    {
        let context = try makeContext()
        let graph = Graph(context: context)
        let upstream = NumberBinaryOperator(context: context)
        let blend = ValueBlendNode(context: context, portType: .NumericVirtual)
        graph.addNode(upstream)
        graph.addNode(blend)
        let source = try #require(blend.port(forKey: .own("inputSource")))
        try #require(graph.connect(upstream.outputNumber, to: source) != nil)
        let afterConnect = blend.strategy

        blend.strategy = NumericPortStrategy.virtual.rawValue
        let afterChoice = blend.strategy
        let wiresBefore = graph.connections.count

        let reopened = try reopen(graph, context: context)
        let reopenedBlend = try #require(reopened.node(forID: blend.id) as? ValueBlendNode)

        print("REVIEW453 explicit-virtual afterConnect=\(afterConnect) afterChoice=\(afterChoice) wires=\(wiresBefore) reopened=\(reopenedBlend.strategy) reopenedWires=\(reopened.connections.count)")
        #expect(afterChoice == NumericPortStrategy.virtual.rawValue)
        #expect(reopenedBlend.strategy == NumericPortStrategy.virtual.rawValue)
    }

    // MARK: Material parameter mirror on reconcile

    @Test("A kept material port's parameter holds the value reconcile applied")
    func reconcileAppliedValueReachesMaterialParameter() throws
    {
        let context = try makeContext()
        let node = DisplacementMaterialNode(context: context)
        node.inputAmount.value = 0.3
        node.reconcilePorts(applying: [PortState(key: .own("Amount"), value: .Float(0.9))])

        let parameterValue = (node.inputAmount.parameter as? FloatParameter)?.value
        print("REVIEW453 material-mirror port=\(String(describing: node.inputAmount.value)) parameter=\(String(describing: parameterValue))")
        #expect(node.inputAmount.value == 0.9)
        #expect(parameterValue == 0.9)
    }
}
