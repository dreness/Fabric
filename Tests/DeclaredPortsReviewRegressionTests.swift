import Foundation
import Metal
import Testing
@testable import Fabric
import Satin

@Suite("Declared Ports Review")
@MainActor
struct DeclaredPortsReviewRegressionTests {
    private func context() throws -> Context {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm, depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
    }

    @Test("Retyping a formatter placeholder keeps the parameter on the port's identity")
    func formatterParameterIdentity() throws {
        let node = StringFormatterNode(context: try context(), formatString: "{amount:f}")
        let before = try #require(node.findPort(named: "amount", as: Fabric.Port.self))
        let graph = Graph(context: node.context)
        let manager = UndoManager()
        manager.groupsByEvent = false
        graph.addNode(node)
        graph.undoManager = manager
        node.apply(FormatStringSettings(formatString: "{amount:d}"))
        let after = try #require(node.findPort(named: "amount", as: Fabric.Port.self))
        #expect(after.portType == .Int)
        #expect(after.id == before.id)
        #expect(after.parameter?.id == after.id)
        let parameter = try #require(after.parameter as? GenericParameter<Int>)
        parameter.value = 7
        manager.removeAllActions()
        manager.beginUndoGrouping()
        parameter.value = 9
        graph.registerValueChange(of: parameter, from: 7, label: "Amount")
        manager.endUndoGrouping()
        graph.undo()
        #expect(parameter.value == 7)
        graph.redo()
        #expect(parameter.value == 9)
    }

    @Test("A declaration factory may ignore the supplied id without splitting parameter identity")
    func factoryParameterIdentity() throws {
        let owner = NumberBinaryOperator(context: try context())
        let registry = PortRegistry()
        _ = registry.reconcile(to: [PortDeclaration(registryKey: "value", port: ParameterPort(parameter: FloatParameter("Value", 3, .inputfield)))], owner: owner, hydrating: nil)
        let original = try #require(registry.port(named: "value"))
        _ = registry.reconcile(to: [PortDeclaration(registryKey: "value", port: ParameterPort(parameter: IntParameter("Value", 4, .inputfield)))], owner: owner, hydrating: nil)
        let replacement = try #require(registry.port(named: "value"))
        #expect(replacement.id == original.id)
        #expect(replacement.parameter?.id == replacement.id)
    }
}
