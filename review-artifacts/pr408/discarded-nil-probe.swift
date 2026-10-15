import Foundation
import Metal
import Satin
import Testing
@testable import Fabric

@Suite("Settings Review Regressions")
@MainActor
struct SettingsReviewRegressionTests
{
    @Test("Reconciliation clears a surviving inlet and leaves runtime outlets alone")
    func reconciliationRestoresAbsentValueInPlace() throws
    {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm,
                              depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
        let node = NumberBinaryOperator(context: context)
        node.inputNumber1.send(nil, force: true)
        let states = node.registry.portStates()
        node.registry.reconciling(to: states)
        {
            node.inputNumber1.value = 17
            node.outputNumber.value = 42
        }
        #expect(node.inputNumber1.value == nil)
        #expect(node.outputNumber.value == 42)
    }

    @Test("Undo restores an absent inlet value, including a published inlet", arguments: [false, true])
    func undoRestoresAbsentValue(published: Bool) throws
    {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm,
                              depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
        let container = SubgraphNode(context: context)
        let graph = container.subGraph
        let node = MathExpressionNode(context: context, expression: "x + y")
        graph.addNode(node)
        let original = try #require(node.findPort(named: "y") as? NodePort<Float>)
        original.send(nil, force: true)
        if published { graph.setPublished(true, on: original) }
        let manager = UndoManager()
        manager.groupsByEvent = false
        graph.undoManager = manager
        graph.setSettings(MathExpressionSettings(stringExpression: "x"), on: node)
        for _ in 0..<2
        {
            graph.undo()
            let restored = try #require(node.findPort(named: "y") as? NodePort<Float>)
            #expect(restored.id == original.id)
            #expect(restored.value == nil, "nil means the upstream value is absent, not the numeric default")
            #expect(restored.published == published)
            if published
            {
                let proxy = try #require(container.ports.first { $0.id == original.id } as? NodePort<Float>)
                #expect(proxy.value == nil)
            }
            graph.redo()
            #expect(node.findPort(named: "y", as: Fabric.Port.self) == nil)
        }
    }
}
