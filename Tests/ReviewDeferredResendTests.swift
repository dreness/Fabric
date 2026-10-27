import Testing
import Foundation
import Metal
import Satin
@testable import Fabric

/// An unchanged synchronous send still takes a sequence number, so a deferred result that lands
/// a frame late loses to it and is discarded.
@Suite("Review: deferred result vs unchanged resend", .serialized)
struct ReviewDeferredResendTests {
    final class ResendingProcessor: Node {
        override class var name: String { "Resending Processor" }
        override class var nodeType: Node.NodeType { .Utility }
        override class var nodeExecutionMode: Node.ExecutionMode { .Processor }
        override class var nodeTimeMode: Node.TimeMode { .None }
        override class var nodeDescription: String { "test" }
        override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)] {
            [("output", NodePort<Int>(name: "Output", kind: .Outlet))]
        }
        var output: NodePort<Int> { port(named: "output") }
        var resendsCurrentValue = true
        override func execute(renderer: GraphRenderer, executionInfo: GraphExecutionInfo,
                              renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) throws {
            let frame = executionInfo.timing.frameNumber
            if resendsCurrentValue { output.send(output.value) }
            let output = self.output
            try commandBuffer.addCompletion { output.send(frame * 10 + 10) }
        }
    }

    /// Each frame's GPU work completes only after the next frame has executed.
    private func run(resends: Bool) throws -> [Int?] {
        let harness = try #require(GraphExecutionTestHarness())
        let graph = Graph(context: harness.context)
        let node = ResendingProcessor(context: harness.context)
        node.resendsCurrentValue = resends
        node.output.published = true
        graph.addNode(node)
        graph.rebuildPublishedParameterGroup()
        let renderer = harness.graphRenderer(for: graph)
        try renderer.startExecution()
        let event = try #require(harness.context.device.makeSharedEvent())
        var previous: MTLCommandBuffer?
        var observed: [Int?] = []
        for number in 0..<8 {
            let commands = try #require(renderer.makeCommandBuffer())
            commands.encodeWaitForEvent(event, value: UInt64(number + 1))
            node.markDirty()
            try renderer.execute(graph: graph, executionInfo: harness.makeExecutionInfo(frameNumber: number),
                                 renderPassDescriptor: MTLRenderPassDescriptor(), commandBuffer: commands)
            commands.commit()
            observed.append(node.output.value)
            event.signaledValue = UInt64(number)
            previous?.waitUntilCompleted()
            previous = commands
        }
        event.signaledValue = 100
        previous?.waitUntilCompleted()
        return observed
    }

    @Test("Without the resend, results one frame late are delivered")
    func control() throws {
        let observed = try run(resends: false)
        print("REVIEW-R2 resend control: observed=\(observed)")
        #expect(observed.compactMap { $0 }.isEmpty == false)
    }

    @Test("Resending the unchanged value does not discard results one frame late")
    func unchangedResend() throws {
        let observed = try run(resends: true)
        print("REVIEW-R2 resend: observed=\(observed)")
        #expect(observed.compactMap { $0 }.isEmpty == false)
    }
}
