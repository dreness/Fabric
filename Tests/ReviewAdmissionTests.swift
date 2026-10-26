import Testing
import Foundation
import Metal
import Satin
@testable import Fabric

/// Finding 4: admission blocks the caller of makeCommandBuffer()/preDraw.
@Suite("Review: admission blocking", .serialized)
struct ReviewAdmissionTests {
    actor Gate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuations.append($0) }
        }
        func open() {
            opened = true
            for continuation in continuations { continuation.resume() }
            continuations.removeAll()
        }
    }

    final class EveryFrameDeferredNode: Node {
        override class var name: String { "Every Frame Deferred" }
        override class var nodeType: Node.NodeType { .Utility }
        override class var nodeExecutionMode: Node.ExecutionMode { .Consumer }
        override class var nodeTimeMode: Node.TimeMode { .None }
        override class var nodeDescription: String { "test" }
        override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)] {
            [("output", NodePort<Int>(name: "Output", kind: .Outlet))]
        }
        var output: NodePort<Int> { port(named: "output") }
        var gate: Gate?
        override func execute(renderer: GraphRenderer, executionInfo: GraphExecutionInfo,
                              renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) throws {
            let output = self.output
            let frame = executionInfo.timing.frameNumber
            if let gate {
                try commandBuffer.addCompletion(operation: { await gate.wait(); return frame },
                                                receive: { output.send($0) })
            } else {
                try commandBuffer.addCompletion { output.send(frame) }
            }
        }
    }

    /// Calls makeCommandBuffer on another thread; true if it returned within `seconds`.
    private func admitsWithin(_ renderer: GraphRenderer, seconds: Double, returned: DispatchSemaphore) -> Bool {
        nonisolated(unsafe) let renderer = renderer
        DispatchQueue.global().async {
            let commands = renderer.makeCommandBuffer()
            commands?.commit()
            returned.signal()
        }
        return returned.wait(timeout: .now() + seconds) == .success
    }

    @Test("Holding maxBuffersInFlight uncommitted command buffers blocks the next makeCommandBuffer")
    func uncommittedBuffersBlock() throws {
        let harness = try #require(GraphExecutionTestHarness())
        let graph = Graph(context: harness.context)
        let node = EveryFrameDeferredNode(context: harness.context)
        graph.addNode(node)
        let renderer = harness.graphRenderer(for: graph)
        try renderer.startExecution()
        defer { try? renderer.stopExecution() }
        let limit = harness.context.maxBuffersInFlight
        var held: [MTLCommandBuffer] = []
        for frame in 0..<limit {
            let commands = try #require(renderer.makeCommandBuffer())
            try renderer.execute(graph: graph, executionInfo: harness.makeExecutionInfo(frameNumber: frame),
                                 renderPassDescriptor: MTLRenderPassDescriptor(), commandBuffer: commands)
            held.append(commands)
        }
        let returned = DispatchSemaphore(value: 0)
        let admitted = admitsWithin(renderer, seconds: 2, returned: returned)
        print("REVIEW4 uncommitted: limit=\(limit) admittedWithin2s=\(admitted)")
        for commands in held { commands.commit(); commands.waitUntilCompleted() }
        let eventuallyAdmitted = admitted || returned.wait(timeout: .now() + 10) == .success
        print("REVIEW4 uncommitted: admittedAfterCommit=\(eventuallyAdmitted)")
        #expect(admitted, "makeCommandBuffer blocked while \(limit) uncommitted buffers were held")
        #expect(eventuallyAdmitted)
    }

    @Test("GPU-complete frames with pending async completions block the next makeCommandBuffer")
    func pendingAsyncOperationsBlock() async throws {
        let harness = try #require(GraphExecutionTestHarness())
        let graph = Graph(context: harness.context)
        let node = EveryFrameDeferredNode(context: harness.context)
        let gate = Gate()
        node.gate = gate
        graph.addNode(node)
        let renderer = harness.graphRenderer(for: graph)
        try renderer.startExecution()
        defer { try? renderer.stopExecution() }
        let limit = harness.context.maxBuffersInFlight
        for frame in 0..<limit {
            let commands = try #require(renderer.makeCommandBuffer())
            try renderer.execute(graph: graph, executionInfo: harness.makeExecutionInfo(frameNumber: frame),
                                 renderPassDescriptor: MTLRenderPassDescriptor(), commandBuffer: commands)
            commands.commit()
            commands.waitUntilCompleted()
            #expect(commands.status == .completed)
        }
        let returned = DispatchSemaphore(value: 0)
        let admitted = admitsWithin(renderer, seconds: 2, returned: returned)
        print("REVIEW4 async: limit=\(limit) admittedWithin2s=\(admitted) (all GPU work completed)")
        await gate.open()
        let eventuallyAdmitted = admitted || returned.wait(timeout: .now() + 10) == .success
        print("REVIEW4 async: admittedAfterGateOpen=\(eventuallyAdmitted)")
        #expect(admitted, "makeCommandBuffer blocked on async completions after GPU finished")
        #expect(eventuallyAdmitted)
    }
}
