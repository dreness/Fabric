import Testing
import Foundation
import Metal
import Satin
@testable import Fabric

/// PR-only: heap count and bytes after the 4K benchmark workload, repeated. Each new heap at least
/// doubles the previous one, so one extra in-flight image can add a full-size heap.
@Suite("Review: heap growth", .serialized)
struct ReviewHeapGrowthTests {
    @Test("8 Render to Image nodes at 4K: heaps after 270 frames, 10 runs")
    func heapGrowthVariance() throws {
        for run in 0 ..< 10 {
            guard let device = MTLCreateSystemDefaultDevice() else { return }
            let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm, depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
            let graph = Graph(context: context)
            for _ in 0 ..< 8 { graph.addNode(ReviewAllocatorEvidenceTests.makeBoxImageNode(context: context, width: 3840, height: 2160)) }
            let renderer = GraphRenderer(context: context, graph: graph)
            renderer.resize(size: (width: 3840, height: 2160), scaleFactor: 1)
            try renderer.startExecution()

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            let target = try #require(device.makeTexture(descriptor: descriptor))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store

            let inFlight = DispatchSemaphore(value: 3)
            var growthFrames: [Int] = []
            var lastHeapCount = 0
            for frame in 0 ..< 270 {
                inFlight.wait()
                let time = Double(frame) / 60
                let info = GraphExecutionInfo(timing: GraphExecutionTiming(time: time, deltaTime: 1.0 / 60, displayTime: time, systemTime: time, hostMediaTime: time, frameNumber: frame), iterationInfo: nil, eventInfo: nil)
                let commands = try #require(renderer.commandQueue.makeCommandBuffer())
                commands.addCompletedHandler { _ in inFlight.signal() }
                try renderer.executeAndDraw(executionInfo: info, renderPassDescriptor: pass, commandBuffer: commands)
                commands.commit()
                let heapCount = context.gpuAllocator.statistics(for: .gpuOnly).heapCount
                if heapCount != lastHeapCount { growthFrames.append(frame); lastHeapCount = heapCount }
            }
            for _ in 0 ..< 3 { inFlight.wait() }
            for _ in 0 ..< 3 { inFlight.signal() }
            let statistics = context.gpuAllocator.statistics(for: .gpuOnly)
            print("HEAPGROWTH run=\(run) heaps=\(statistics.heapCount) heap_MB=\(statistics.heapBytes >> 20) used_MB=\(statistics.usedBytes >> 20) new_heap_frames=\(growthFrames)")
            try renderer.cleanup()
        }
    }
}
