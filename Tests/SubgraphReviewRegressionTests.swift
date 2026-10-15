import Foundation
import Metal
import Satin
import Testing
@testable import Fabric

@Suite("Subgraph Review Regressions")
@MainActor
struct SubgraphReviewRegressionTests
{
    @Test("Embedding keeps a boundary outlet's last value", arguments: [false, true])
    func embeddingKeepsOutletValue(deferred: Bool) throws
    {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm,
                              depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
        let graph = Graph(context: context)
        let source = NumberBinaryOperator(context: context)
        let sink = NumberBinaryOperator(context: context)
        graph.addNode(source)
        graph.addNode(sink)
        source.outputNumber.send(42, force: true)
        graph.connect(source.outputNumber, to: sink.inputNumber1)
        let container = try graph.createSubgraph(from: [source], centeredOn: source,
                                                usingClass: deferred ? DeferredSubgraphNode.self : SubgraphNode.self)
        #expect(source.outputNumber.value == 42)
        let proxy = try #require(container.ports.first { $0.id == source.outputNumber.id } as? NodePort<Float>)
        #expect(proxy.value == 42)
    }

    @Test("A rejected embedding leaves supported boundary values untouched")
    func rejectedEmbeddingIsReadOnly() throws
    {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm,
                              depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
        let graph = Graph(context: context)
        let source = NumberBinaryOperator(context: context)
        let moved = NumberBinaryOperator(context: context)
        let unsupportedInput = NodePort<ContiguousArray<ContiguousArray<Float>>>(name: "Nested", kind: .Inlet)
        let unsupportedOutput = NodePort<ContiguousArray<ContiguousArray<Float>>>(name: "Nested", kind: .Outlet)
        moved.addDynamicPort(unsupportedInput)
        source.addDynamicPort(unsupportedOutput)
        graph.addNode(source)
        graph.addNode(moved)
        source.outputNumber.value = 42
        graph.connect(source.outputNumber, to: moved.inputNumber1)
        graph.connect(unsupportedOutput, to: unsupportedInput)
        let idsBefore = graph.connections.map(\.id)
        let manager = UndoManager()
        manager.groupsByEvent = false
        graph.undoManager = manager
        var changes = 0
        moved.inputNumber1.onValueChanged = { changes += 1 }
        #expect(throws: FabricError.self)
        {
            try graph.createSubgraph(from: [moved], centeredOn: moved, usingClass: SubgraphNode.self)
        }
        #expect(moved.inputNumber1.value == 42)
        #expect(changes == 0)
        #expect(graph.connections.map(\.id) == idsBefore)
        #expect(graph.nodes.count == 2)
        #expect(!manager.canUndo)
    }

    @Test("Proxy preflight leaves live values and change callbacks untouched")
    func proxyPreflightIsReadOnly() throws
    {
        let port = NodePort<Float>(name: "Output", kind: .Outlet)
        port.value = 42
        var changes = 0
        port.onValueChanged = { changes += 1 }
        #expect(SubgraphNode.canProxy(port))
        #expect(port.value == 42)
        #expect(changes == 0)
    }

    @Test("Nested embedding preserves fan-out and prior edit targets through undo and redo")
    func nestedEmbeddingPreservesHistory() throws
    {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm,
                              depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
        let root = Graph(context: context)
        let outer = SubgraphNode(context: context)
        root.addNode(outer)
        let graph = outer.subGraph
        let source = NumberBinaryOperator(context: context)
        let moved = MathExpressionNode(context: context, expression: "x + y")
        let sinkA = NumberBinaryOperator(context: context)
        let sinkB = NumberBinaryOperator(context: context)
        for node in [source, moved, sinkA, sinkB] { graph.addNode(node) }
        let x = try #require(moved.findPort(named: "x", as: Fabric.Port.self))
        let output = try #require(moved.outputPorts().first)
        graph.connect(source.outputNumber, to: x)
        graph.connect(output, to: sinkA.inputNumber1)
        let disabled = try #require(graph.connect(output, to: sinkB.inputNumber1))
        graph.setConnection(disabled, active: false)
        let idsBefore = Set(graph.connections.map(\.id))
        let manager = UndoManager()
        manager.groupsByEvent = false
        root.undoManager = manager
        graph.setSettings(MathExpressionSettings(stringExpression: "x + y + 1"), on: moved)
        let inner = try graph.createSubgraph(from: [moved, moved], centeredOn: moved, usingClass: SubgraphNode.self)
        #expect(inner.subGraph.nodes.count == 1)
        #expect(graph.connections.count == 3)
        #expect(graph.connections.filter { !$0.active }.count == 1)
        inner.subGraph.setSettings(MathExpressionSettings(stringExpression: "x + y + 2"), on: moved)
        root.undo()
        #expect(moved.stringExpression == "x + y + 1")
        for _ in 0..<2
        {
            root.undo()
            #expect(moved.graph === graph)
            #expect(Set(graph.connections.map(\.id)) == idsBefore)
            root.undo()
            #expect(moved.stringExpression == "x + y")
            root.redo()
            root.redo()
            #expect(moved.graph === inner.subGraph)
            #expect(graph.connections.count == 3)
            #expect(graph.connections.filter { !$0.active }.count == 1)
        }
        root.redo()
        #expect(moved.stringExpression == "x + y + 2")
    }
}
