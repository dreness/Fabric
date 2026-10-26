import Testing
import Foundation
import Metal
import Satin
@testable import Fabric

/// Finding 1: ContourPath next-frame mode inside an Iterator.
@Suite("Review: Contour in Iterator", .serialized)
struct ReviewContourIteratorTests {
    /// Sends masks[currentIteration].
    final class IterationMaskNode: Node {
        override class var name: String { "Iteration Mask" }
        override class var nodeType: Node.NodeType { .Utility }
        override class var nodeExecutionMode: Node.ExecutionMode { .Provider }
        override class var nodeTimeMode: Node.TimeMode { .None }
        override class var nodeDescription: String { "test" }
        override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)] {
            super.registerPorts(context: context) + [("output", NodePort<FabricImage>(name: "Mask", kind: .Outlet))]
        }
        var output: NodePort<FabricImage> { port(named: "output") }
        var masks: [FabricImage] = []
        override func execute(renderer: GraphRenderer, executionInfo: GraphExecutionInfo,
                              renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) throws {
            output.send(masks[executionInfo.iterationInfo?.currentIteration ?? 0])
        }
    }

    final class ContourRecorder: Node {
        override class var name: String { "Contour Recorder" }
        override class var nodeType: Node.NodeType { .Utility }
        override class var nodeExecutionMode: Node.ExecutionMode { .Consumer }
        override class var nodeTimeMode: Node.TimeMode { .None }
        override class var nodeDescription: String { "test" }
        override class func registerPorts(context: Context) -> [(name: String, port: Fabric.Port)] {
            super.registerPorts(context: context) + [("input", NodePort<ContiguousArray<SIMD2<Float>>>(name: "Contour", kind: .Inlet))]
        }
        var input: NodePort<ContiguousArray<SIMD2<Float>>> { port(named: "input") }
        /// (frame, iteration, maxX of contour or -1)
        var records: [(frame: Int, iteration: Int, maxX: Float)] = []
        override func execute(renderer: GraphRenderer, executionInfo: GraphExecutionInfo,
                              renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) throws {
            let maxX = input.value.map { points in (points.map(\.x).reduce(0, +) / Float(max(points.count, 1))).rounded() } ?? -1
            records.append((executionInfo.timing.frameNumber, executionInfo.iterationInfo?.currentIteration ?? -1, maxX))
        }
    }

    /// 16x16 mask with a filled 3x3 square at x [originX, originX+3), y [2, 5).
    private func mask(_ harness: GraphExecutionTestHarness, side originX: Int) throws -> FabricImage {
        let size = 16
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: size, height: size, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try #require(harness.context.device.makeTexture(descriptor: descriptor))
        var values = [Float](repeating: 0, count: size * size)
        for y in 2..<5 { for x in originX..<(originX + 3) { values[y * size + x] = 1 } }
        values.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: size * 4)
        }
        return .unmanaged(texture: texture)
    }

    private func run(mode: GPUResultDeliveryMode, frames: Int, sides: [Int] = [1, 6, 11]) throws -> [(frame: Int, iteration: Int, maxX: Float)] {
        let harness = try #require(GraphExecutionTestHarness())
        let graph = Graph(context: harness.context)
        let iterator = IteratorNode(context: harness.context)
        iterator.inputIteratonCount.value = sides.count
        let source = IterationMaskNode(context: harness.context)
        source.masks = try sides.map { try mask(harness, side: $0) }
        let contour = ContourPathNode(context: harness.context)
        contour.resultDeliveryMode = mode
        contour.inputMaxSegments.value = 4096
        let recorder = ContourRecorder(context: harness.context)
        iterator.subGraph.addNode(source)
        iterator.subGraph.addNode(contour)
        iterator.subGraph.addNode(recorder)
        iterator.subGraph.connect(source.output, to: contour.inputMask)
        iterator.subGraph.connect(contour.outputContour, to: recorder.input)
        graph.addNode(iterator)
        let renderer = harness.graphRenderer(for: graph)
        try renderer.startExecution()
        defer { try? renderer.stopExecution() }
        for frame in 0..<frames {
            let commands = try #require(renderer.makeCommandBuffer())
            try renderer.execute(graph: graph, executionInfo: harness.makeExecutionInfo(frameNumber: frame),
                                 renderPassDescriptor: MTLRenderPassDescriptor(), commandBuffer: commands)
            commands.commit()
            commands.waitUntilCompleted()
            #expect(commands.status == .completed)
        }
        return recorder.records
    }

    @Test("Each iteration receives its own contour in next-frame mode")
    func perIterationContour() throws {
        for side in [1, 6, 11] {
            print("REVIEW1 single-iteration side \(side): same=\(try run(mode: .sameFrame, frames: 1, sides: [side]).map(\.maxX)) next=\(try run(mode: .nextFrame, frames: 2, sides: [side]).map(\.maxX))")
        }
        let reference = try run(mode: .sameFrame, frames: 1)
        print("REVIEW1 sameFrame records:", reference.map { "f\($0.frame) i\($0.iteration) meanX=\($0.maxX)" })
        // Masks occupy disjoint x ranges; classify a contour by which mask it came from.
        func source(_ meanX: Float) -> Int { meanX < 0 ? -1 : meanX < 5 ? 0 : meanX < 10 ? 1 : 2 }
        let expected = reference.map { source($0.maxX) }
        #expect(expected == [0, 1, 2])
        let deferred = try run(mode: .nextFrame, frames: 4)
        print("REVIEW1 nextFrame records:", deferred.map { "f\($0.frame) i\($0.iteration) meanX=\($0.maxX)" })
        for frame in 1..<4 {
            let got = deferred.filter { $0.frame == frame }.map { source($0.maxX) }
            #expect(got == expected, "frame \(frame): per-iteration contour sources \(got), expected \(expected)")
        }
    }
}
