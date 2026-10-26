import Testing
import Foundation
import Metal
import Satin
@testable import Fabric

/// Finding 6: execute(graph:) on an Iterator graph leaves pendingSubmission cached.
@Suite("Review: stale frame submission", .serialized)
struct ReviewStaleSubmissionTests {
    final class OffsetMeshNode: MeshNode {
        var placementX: Float = 0
        override public func execute(renderer: GraphRenderer, executionInfo: GraphExecutionInfo,
                                     renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) throws {
            try super.execute(renderer: renderer, executionInfo: executionInfo,
                              renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
            object?.position = [placementX, 0, 0]
        }
    }

    private func pixels(_ texture: MTLTexture, _ harness: GraphExecutionTestHarness) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                                  height: texture.height, mipmapped: false)
        descriptor.storageMode = .shared
        let readback = try #require(harness.context.device.makeTexture(descriptor: descriptor))
        let commands = try #require(harness.renderer.commandQueue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(from: texture, to: readback)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            readback.getBytes(buffer.baseAddress!, bytesPerRow: texture.width * 4,
                              from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }

    private func meshGraph(_ harness: GraphExecutionTestHarness, into graph: Graph, offset: Float) -> OffsetMeshNode {
        let geometry = BoxGeometryNode(context: harness.context)
        let material = BasicColorMaterialNode(context: harness.context)
        let mesh = OffsetMeshNode(context: harness.context)
        mesh.placementX = offset
        mesh.inputScale.value = .init(repeating: 0.3)
        graph.addNode(geometry)
        graph.addNode(material)
        graph.addNode(mesh)
        graph.connect(geometry.outputGeometry, to: mesh.inputGeometry)
        graph.connect(material.outputMaterial, to: mesh.inputMaterial)
        return mesh
    }

    @Test("A later frame's submission carries the later frame time")
    func submissionFrameTime() throws {
        let harness = try #require(GraphExecutionTestHarness())
        let graph = Graph(context: harness.context)
        let iterator = IteratorNode(context: harness.context)
        iterator.inputIteratonCount.value = 1
        _ = meshGraph(harness, into: iterator.subGraph, offset: 0)
        graph.addNode(iterator)
        let renderer = harness.graphRenderer(for: graph)
        try renderer.startExecution()
        defer { try? renderer.stopExecution() }
        try harness.execute(graph, frameNumber: 0)
        let later = harness.makeExecutionInfo(frameNumber: 9).timing
        let submission = renderer.frameSubmission(frame: later)
        let target = try harness.makeTexture()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        let commands = try #require(renderer.commandQueue.makeCommandBuffer())
        try submission.record(scene: graph.scene, renderPassDescriptor: pass, preparationCommandBuffer: commands)
        let sealed = try submission.seal()
        print("REVIEW6 requested frame 9, submission frame=\(sealed.frame.frameNumber) time=\(sealed.frame.time)")
        #expect(sealed.frame.frameNumber == 9)
    }

    @Test("executeAndDraw after a direct execute draws only the current frame's iteration records")
    func staleRecordsAfterDirectExecute() throws {
        let harness = try #require(GraphExecutionTestHarness())
        let graph = Graph(context: harness.context)
        let iterator = IteratorNode(context: harness.context)
        iterator.inputIteratonCount.value = 1
        let mesh = meshGraph(harness, into: iterator.subGraph, offset: -0.5)
        graph.addNode(iterator)
        let reference = Graph(context: harness.context)
        _ = meshGraph(harness, into: reference, offset: 0.5)
        let renderer = harness.graphRenderer(for: graph)
        try renderer.startExecution()
        try harness.graphRenderer(for: reference).startExecution()
        defer {
            try? renderer.stopExecution()
            try? harness.graphRenderer(for: reference).stopExecution()
        }
        try harness.execute(graph, frameNumber: 0)  // direct execute(graph:), not drawn
        mesh.placementX = 0.5
        let drawn = try pixels(harness.execute(graph: graph, executionInfo: harness.makeExecutionInfo(frameNumber: 1), drawScene: true), harness)
        let expected = try pixels(harness.execute(graph: reference, executionInfo: harness.makeExecutionInfo(frameNumber: 1), drawScene: true), harness)
        let lit = { (bytes: [UInt8]) in stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] | bytes[$0 + 1] | bytes[$0 + 2] != 0 }.count }
        print("REVIEW6 litPixels drawn=\(lit(drawn)) expected=\(lit(expected)) identical=\(drawn == expected)")
        #expect(drawn == expected)
    }
}
