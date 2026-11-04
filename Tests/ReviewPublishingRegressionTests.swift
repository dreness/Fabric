import Foundation
import Metal
import Testing
@testable import Fabric
import Satin

@Suite("Publishing review regressions")
@MainActor
struct PublishingReviewRegressionTests {
    private func context() throws -> Context {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm,
                       depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
    }

    @Test("Replacing an inlet preserves the node's cached upstream dependency")
    func replacementInletKeepsDependency() throws {
        let harness = try #require(GraphExecutionTestHarness())
        let context = harness.context
        let graph = Graph(context: context)
        let source = NumberBinaryOperator(context: context)
        let target = NumberBinaryOperator(context: context)
        graph.addNode(source)
        graph.addNode(target)
        let old = target.inputNumber1
        let wire = try #require(graph.connect(source.outputNumber, to: old))
        let renderer = harness.graphRenderer(for: graph)
        try renderer.startExecution()
        #expect(target.executionState == .started)
        let replacement = NodePort<Float>(name: old.name, kind: .Inlet, id: old.id)
        target.replacePort(old, with: replacement)
        #expect(wire.inletPort === replacement)
        try renderer.synchronizeLifecycle()
        #expect(target.executionState == .started)
        #expect(target.inputNodes.contains { $0 === source })
        #expect(source.outputNodes.contains { $0 === target })
    }

    @Test("Replacing an outlet preserves the node's cached downstream dependency")
    func replacementOutletKeepsDependency() throws {
        let context = try context()
        let graph = Graph(context: context)
        let source = NumberBinaryOperator(context: context)
        let target = NumberBinaryOperator(context: context)
        graph.addNode(source)
        graph.addNode(target)
        let old = source.outputNumber
        let wire = try #require(graph.connect(old, to: target.inputNumber1))
        let replacement = NodePort<Float>(name: old.name, kind: .Outlet, id: old.id)
        source.replacePort(old, with: replacement)
        #expect(wire.outletPort === replacement)
        #expect(source.outputNodes.contains { $0 === target })
        #expect(target.inputNodes.contains { $0 === source })
    }

    @Test("Retyping a published inlet preserves the subgraph's upstream dependency")
    func replacementProxyKeepsDependency() throws {
        let context = try context()
        let graph = Graph(context: context)
        let source = NumberBinaryOperator(context: context)
        let container = SubgraphNode(context: context)
        let target = NumberBinaryOperator(context: context)
        graph.addNode(source)
        graph.addNode(container)
        container.subGraph.addNode(target)
        let old = target.inputNumber1
        container.subGraph.setPublished(true, on: old)
        let proxy = try #require(container.ports.first { $0.id == old.id })
        let wire = try #require(graph.connect(source.outputNumber, to: proxy))
        let replacement = NodePort<Int>(name: old.name, kind: .Inlet, id: old.id)
        target.replacePort(old, with: replacement)
        let remade = try #require(container.ports.first { $0.id == old.id })
        #expect(remade !== proxy)
        #expect(wire.inletPort === remade)
        #expect(container.inputNodes.contains { $0 === source })
        #expect(source.outputNodes.contains { $0 === container })
    }
    @Test("Sample and Hold settings retain a compatible incoming wire and execution")
    func strategyChangeKeepsExecution() throws {
        let harness = try #require(GraphExecutionTestHarness())
        let context = harness.context
        let graph = Graph(context: context)
        let source = NumberBinaryOperator(context: context)
        let target = SampleAndHoldNode(context: context)
        target.strategy = PortType.Float.rawValue
        graph.addNode(source)
        graph.addNode(target)
        let inlet: Fabric.Port = try #require(target.findPort(named: "inputValue"))
        let wire = try #require(graph.connect(source.outputNumber, to: inlet))
        let renderer = harness.graphRenderer(for: graph)
        try renderer.startExecution()
        #expect(target.executionState == .started)
        target.strategy = PortType.Int.rawValue
        let replacement: Fabric.Port = try #require(target.findPort(named: "inputValue"))
        #expect(wire.inletPort === replacement)
        try renderer.synchronizeLifecycle()
        #expect(target.executionState == .started)
        #expect(target.inputNodes.contains { $0 === source })
    }

}
