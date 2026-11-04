import Testing
import Foundation
import Metal
import Satin
@testable import Fabric

/// Finding 5: Render to Image under an MSAA context; newImage(copying:) requires sampleCount == 1.
@Suite("Review: Render to Image MSAA", .serialized)
struct ReviewMSAARenderToImageTests {
    private func readFloats(_ texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) throws -> [Float] {
        let bytesPerRow = texture.width * 4
        let buffer = try #require(device.makeBuffer(length: bytesPerRow * texture.height, options: .storageModeShared))
        let commands = try #require(queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let pointer = buffer.contents().assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: pointer, count: texture.width * texture.height))
    }

    private func readBytes(_ texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) throws -> [UInt8] {
        let bytesPerRow = texture.width * 4
        let buffer = try #require(device.makeBuffer(length: bytesPerRow * texture.height, options: .storageModeShared))
        let commands = try #require(queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let pointer = buffer.contents().assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: bytesPerRow * texture.height))
    }

    @Test("Render to Image publishes color and depth", arguments: [1, 4])
    func renderToImage(sampleCount: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let context = Context(device: device, sampleCount: sampleCount, colorPixelFormat: .bgra8Unorm,
                              depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
        let inside = Graph(context: context)
        let geometry = BoxGeometryNode(context: context)
        let material = BasicColorMaterialNode(context: context)
        let mesh = MeshNode(context: context)
        mesh.inputScale.value = .init(repeating: 0.5)
        inside.addNode(geometry)
        inside.addNode(material)
        inside.addNode(mesh)
        inside.connect(geometry.outputGeometry, to: mesh.inputGeometry)
        inside.connect(material.outputMaterial, to: mesh.inputMaterial)
        let imageNode = DeferredSubgraphNode(context: context, subGraph: inside)
        imageNode.inputWidth.value = 64
        imageNode.inputHeight.value = 64
        let outer = Graph(context: context)
        outer.addNode(imageNode)
        imageNode.outputDepthTexture.published = true
        imageNode.outputColorTexture.published = true
        outer.rebuildPublishedParameterGroup()
        let renderer = GraphRenderer(context: context, graph: outer)
        renderer.resize(size: (64, 64), scaleFactor: 1)
        let errors = RecordingErrorDelegate()
        renderer.errorDelegate = errors
        try renderer.startExecution()
        defer { try? renderer.stopExecution() }
        var thrown: [String] = []
        for frame in 0..<3 {
            let commands = try #require(renderer.makeCommandBuffer())
            do {
                try renderer.execute(graph: outer,
                                     executionInfo: GraphExecutionInfo(timing: .init(time: Double(frame), deltaTime: 0, displayTime: Double(frame),
                                                                                     systemTime: Double(frame), hostMediaTime: Double(frame), frameNumber: frame),
                                                                        iterationInfo: nil, eventInfo: nil),
                                     renderPassDescriptor: MTLRenderPassDescriptor(), commandBuffer: commands)
            } catch { thrown.append("\(error)") }
            commands.commit()
            commands.waitUntilCompleted()
            if let error = commands.error { thrown.append("GPU: \(error)") }
        }
        let innerDepth = imageNode.graphRenderer.renderEncoder.depthTexture
        let depth = imageNode.outputDepthTexture.value
        let color = imageNode.outputColorTexture.value
        var depthCovered = -1
        var colorCovered = -1
        if let depth { let values = try readFloats(depth.texture, device: device, queue: renderer.commandQueue); depthCovered = Set(values).count; print("REVIEW5 depth sampleCount=\(depth.texture.sampleCount) min=\(values.min() ?? -1) max=\(values.max() ?? -1)") }
        if let color {
            let bytes = try readBytes(color.texture, device: device, queue: renderer.commandQueue)
            colorCovered = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0 + 3] != 0 }.count
        }
        print("REVIEW5 sampleCount=\(sampleCount) thrown=\(thrown) delegateErrors=\(errors.reportedErrors.map { "\($0)" }) innerDepthSampleCount=\(innerDepth?.sampleCount ?? -1) depthOut=\(depth != nil) depthCovered=\(depthCovered) colorOut=\(color != nil) colorCovered=\(colorCovered)/4096")
        #expect(thrown.isEmpty)
        #expect(errors.reportedErrors.isEmpty)
        #expect(depth != nil)
        #expect(depthCovered > 1, "depth has \(depthCovered) distinct values")
        #expect(colorCovered > 0)
    }
}
