import Testing
import Foundation
import Metal
import Satin
@testable import Fabric

/// Finding 2: invalidate() clears slots but participatingIndices remain; publish sends nil each frame.
@Suite("Review: deferred invalidate", .serialized)
struct ReviewDeferredInvalidateTests {
    final class MixedProcessor: Node {
        override class var name: String { "Mixed Processor" }
        override class var nodeType: Node.NodeType { .Utility }
        override class var nodeExecutionMode: Node.ExecutionMode { .Processor }
        override class var nodeTimeMode: Node.TimeMode { .None }
        override class var nodeDescription: String { "test" }
        override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)] {
            [("output", NodePort<Int>(name: "Output", kind: .Outlet))]
        }
        var output: NodePort<Int> { port(named: "output") }
        /// frame -> synchronous value to send at that frame
        var synchronousSends: [Int: Int] = [:]
        var executedFrames: [Int] = []
        override func execute(renderer: GraphRenderer, executionInfo: GraphExecutionInfo,
                              renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) throws {
            let frame = executionInfo.timing.frameNumber
            executedFrames.append(frame)
            if frame == 0 {
                let output = self.output
                try commandBuffer.addCompletion { output.send(10) }
            }
            if let value = synchronousSends[frame] { output.send(value) }
        }
    }

    private func frame(_ renderer: GraphRenderer, _ graph: Graph, _ harness: GraphExecutionTestHarness, _ number: Int) throws {
        let commands = try #require(renderer.makeCommandBuffer())
        try renderer.execute(graph: graph, executionInfo: harness.makeExecutionInfo(frameNumber: number),
                             renderPassDescriptor: MTLRenderPassDescriptor(), commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
    }

    private func setUp() throws -> (GraphExecutionTestHarness, Graph, MixedProcessor, GraphRenderer) {
        let harness = try #require(GraphExecutionTestHarness())
        let graph = Graph(context: harness.context)
        let node = MixedProcessor(context: harness.context)
        node.output.published = true
        graph.addNode(node)
        graph.rebuildPublishedParameterGroup()
        let renderer = harness.graphRenderer(for: graph)
        try renderer.startExecution()
        return (harness, graph, node, renderer)
    }

    @Test("After cancelPendingCompletions, a synchronous send survives clean frames")
    func cancelThenSynchronousSend() throws {
        let (harness, graph, node, renderer) = try setUp()
        node.synchronousSends[2] = 5
        var observed: [Int?] = []
        try frame(renderer, graph, harness, 0); observed.append(node.output.value)
        try frame(renderer, graph, harness, 1); observed.append(node.output.value)  // delivers 10
        node.cancelPendingCompletions()
        node.markDirty()
        try frame(renderer, graph, harness, 2); observed.append(node.output.value)  // sends 5
        for number in 3..<6 { try frame(renderer, graph, harness, number); observed.append(node.output.value) }
        print("REVIEW2 cancel: observed=\(observed) executed=\(node.executedFrames)")
        #expect(observed == [nil, 10, 5, 5, 5, 5])
    }

    @Test("Without cancellation, a later synchronous send survives clean frames")
    func synchronousSendAfterDelivery() throws {
        let (harness, graph, node, renderer) = try setUp()
        node.synchronousSends[2] = 5
        var observed: [Int?] = []
        try frame(renderer, graph, harness, 0); observed.append(node.output.value)
        try frame(renderer, graph, harness, 1); observed.append(node.output.value)
        node.markDirty()
        try frame(renderer, graph, harness, 2); observed.append(node.output.value)
        for number in 3..<6 { try frame(renderer, graph, harness, number); observed.append(node.output.value) }
        print("REVIEW2 nocancel: observed=\(observed) executed=\(node.executedFrames)")
        #expect(observed == [nil, 10, 5, 5, 5, 5])
    }
}
