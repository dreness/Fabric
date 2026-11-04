import Testing
import Foundation
import Metal
import Satin
@testable import Fabric

/// Evidence for PR #443 (GPU allocator). Identical source compiled against base and PR.
/// FABRIC_TREE labels output; FABRIC_BENCH_WIDTH / FABRIC_BENCH_HEIGHT set the render size.
@Suite("Review: allocator evidence", .serialized)
struct ReviewAllocatorEvidenceTests {
    static let tree = ProcessInfo.processInfo.environment["FABRIC_TREE"] ?? "unknown"
    static let width = Int(ProcessInfo.processInfo.environment["FABRIC_BENCH_WIDTH"] ?? "") ?? 1920
    static let height = Int(ProcessInfo.processInfo.environment["FABRIC_BENCH_HEIGHT"] ?? "") ?? 1080

    static func threadCPUNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    static func makeBoxImageNode(context: Context, width: Int, height: Int) -> DeferredSubgraphNode {
        let imageNode = DeferredSubgraphNode(context: context)
        imageNode.inputWidth.value = width
        imageNode.inputHeight.value = height
        let geometry = BoxGeometryNode(context: context)
        let material = BasicColorMaterialNode(context: context)
        let mesh = MeshNode(context: context)
        imageNode.subGraph.addNode(geometry)
        imageNode.subGraph.addNode(material)
        imageNode.subGraph.addNode(mesh)
        imageNode.subGraph.connect(geometry.outputGeometry, to: mesh.inputGeometry)
        imageNode.subGraph.connect(material.outputMaterial, to: mesh.inputMaterial)
        return imageNode
    }

    /// N Render to Image nodes, each drawing a box at the bench size, rendered with 3 frames in flight.
    @Test("Render to Image benchmark: CPU, GPU and device memory", arguments: [1, 8])
    func renderToImageBenchmark(nodeCount: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let width = Self.width, height = Self.height
        let baselineBytes = device.currentAllocatedSize
        let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm, depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
        let graph = Graph(context: context)
        for _ in 0 ..< nodeCount { graph.addNode(Self.makeBoxImageNode(context: context, width: width, height: height)) }
        let renderer = GraphRenderer(context: context, graph: graph)
        renderer.resize(size: (width: Float(width), height: Float(height)), scaleFactor: 1)
        try renderer.startExecution()
        defer { try? renderer.stopExecution() }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store

        let warmupFrames = 30, measuredFrames = 240
        let inFlight = DispatchSemaphore(value: 3)
        var cpuSamples: [Double] = []
        var gpuSamples: [Double] = []
        let gpuLock = NSLock()
        var peakBytes = 0
        for frame in 0 ..< (warmupFrames + measuredFrames) {
            inFlight.wait()
            let time = Double(frame) / 60
            let info = GraphExecutionInfo(timing: GraphExecutionTiming(time: time, deltaTime: 1.0 / 60, displayTime: time, systemTime: time, hostMediaTime: time, frameNumber: frame), iterationInfo: nil, eventInfo: nil)
            let cpuBefore = Self.threadCPUNanoseconds()
            let commands = try #require(renderer.commandQueue.makeCommandBuffer())
            commands.addCompletedHandler { buffer in
                if frame >= warmupFrames {
                    let gpu = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                    gpuLock.withLock { gpuSamples.append(gpu) }
                }
                inFlight.signal()
            }
            try renderer.executeAndDraw(executionInfo: info, renderPassDescriptor: pass, commandBuffer: commands)
            commands.commit()
            if frame >= warmupFrames { cpuSamples.append(Double(Self.threadCPUNanoseconds() - cpuBefore) / 1e6) }
            peakBytes = max(peakBytes, device.currentAllocatedSize - baselineBytes)
        }
        for _ in 0 ..< 3 { inFlight.wait() }
        for _ in 0 ..< 3 { inFlight.signal() }
        let cpu = cpuSamples.sorted()[cpuSamples.count / 2]
        let gpuSorted = gpuLock.withLock { gpuSamples.sorted() }
        let gpu = gpuSorted[gpuSorted.count / 2]
        let settledBytes = device.currentAllocatedSize - baselineBytes
        print(String(format: "ALLOCBENCH tree=%@ nodes=%d size=%dx%d cpu_ms=%.3f gpu_ms=%.3f peak_MB=%.1f settled_MB=%.1f",
                     Self.tree, nodeCount, width, height, cpu, gpu, Double(peakBytes) / 1_048_576, Double(settledBytes) / 1_048_576))
    }

    /// At ddab23b8 a 4K bgra8 image was over the 32 MB `dedicatedThreshold`, so it skipped the heaps.
    @Test("A 3840x2160 image comes from a heap")
    func fourKImageUsesHeap() throws {
        guard let harness = GraphExecutionTestHarness(renderWidth: 4, renderHeight: 4) else { return }
        let image = try harness.renderer.newImage(withWidth: 3840, height: 2160, format: .bgra8Unorm)
        print("ALLOC4K tree=\(Self.tree) heap=\(image.texture.heap != nil) bytes=\(image.texture.allocatedSize)")
        #expect(image.texture.heap != nil)
    }

    /// One Render to Image node whose size steps from 960x540 to 3840x2160 (a live window resize or an
    /// animated size), then drops back to 960x540. Heaps are not trimmed while running, so the settled
    /// figure shows what the sweep leaves behind.
    @Test("Render to Image resize sweep: peak and retained device memory")
    func resizeSweep() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let baselineBytes = device.currentAllocatedSize
        let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm, depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
        let graph = Graph(context: context)
        let imageNode = Self.makeBoxImageNode(context: context, width: 960, height: 540)
        graph.addNode(imageNode)
        let renderer = GraphRenderer(context: context, graph: graph)
        renderer.resize(size: (width: 960, height: 540), scaleFactor: 1)
        try renderer.startExecution()
        defer { try? renderer.stopExecution() }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store

        let steps = 16, framesPerStep = 10, settleFrames = 60
        let inFlight = DispatchSemaphore(value: 3)
        var peakBytes = 0
        var frame = 0
        func render(width: Int, height: Int, frames: Int) throws {
            imageNode.inputWidth.value = width
            imageNode.inputHeight.value = height
            for _ in 0 ..< frames {
                inFlight.wait()
                let time = Double(frame) / 60
                let info = GraphExecutionInfo(timing: GraphExecutionTiming(time: time, deltaTime: 1.0 / 60, displayTime: time, systemTime: time, hostMediaTime: time, frameNumber: frame), iterationInfo: nil, eventInfo: nil)
                let commands = try #require(renderer.commandQueue.makeCommandBuffer())
                commands.addCompletedHandler { _ in inFlight.signal() }
                try renderer.executeAndDraw(executionInfo: info, renderPassDescriptor: pass, commandBuffer: commands)
                commands.commit()
                peakBytes = max(peakBytes, device.currentAllocatedSize - baselineBytes)
                frame += 1
            }
        }
        for step in 0 ... steps {
            let width = 960 + (3840 - 960) * step / steps
            try render(width: width, height: width * 9 / 16, frames: framesPerStep)
        }
        try render(width: 960, height: 540, frames: settleFrames)
        for _ in 0 ..< 3 { inFlight.wait() }
        for _ in 0 ..< 3 { inFlight.signal() }
        let settledBytes = device.currentAllocatedSize - baselineBytes
        print(String(format: "ALLOCSWEEP tree=%@ peak_MB=%.1f settled_MB=%.1f", Self.tree, Double(peakBytes) / 1_048_576, Double(settledBytes) / 1_048_576))
    }

    /// Unconnected depth is nil on the PR; connecting it must produce an image on the next frame.
    @Test("Depth output connected after the node ran gets an image on the next frame")
    func depthConnectedLater() throws {
        guard let harness = GraphExecutionTestHarness(renderWidth: 64, renderHeight: 32) else { return }
        let graph = Graph(context: harness.context)
        let imageNode = Self.makeBoxImageNode(context: harness.context, width: 64, height: 32)
        let consumer = PassThroughNode<FabricImage>(context: harness.context)
        graph.addNode(imageNode)
        graph.addNode(consumer)
        let renderer = harness.graphRenderer(for: graph)
        try renderer.startExecution()
        defer { try? renderer.stopExecution() }
        for frame in 0 ..< 3 {
            try harness.render(graph: graph, executionInfo: harness.makeExecutionInfo(frameNumber: frame))
        }
        let depthBefore = imageNode.outputDepthTexture.value
        graph.connect(imageNode.outputDepthTexture, to: consumer.input)
        try harness.render(graph: graph, executionInfo: harness.makeExecutionInfo(frameNumber: 3))
        print("ALLOCLATE tree=\(Self.tree) depthBefore=\(depthBefore != nil) depthAfter=\(imageNode.outputDepthTexture.value != nil)")
        #expect(imageNode.outputDepthTexture.value != nil)
    }
}
