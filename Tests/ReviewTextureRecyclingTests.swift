import Testing
import Foundation
import Metal
@testable import Fabric

/// Finding 3: one pending execution anywhere in the process suspends recycling for every cache.
@Suite("Review: process-wide recycling stall", .serialized)
struct ReviewTextureRecyclingTests {
    @Test("A slow unrelated GPU frame stops another cache from reusing its textures")
    func unrelatedPendingFrameStallsRecycling() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var configuration = GraphRendererTextureCache.Configuration()
        configuration.framePoolCount = 1
        configuration.minimumHeapSizeBytes = 1024 * 1024
        let unrelatedCache = GraphRendererTextureCache(device: device, config: configuration, recycling: .shared)

        // Baseline: no pending execution, immediate reuse.
        var baselineTextures = Set<ObjectIdentifier>()
        for _ in 0..<5 {
            var image: FabricImage? = try #require(unrelatedCache.newManagedImage(width: 4, height: 4, pixelFormat: .rgba8Unorm))
            baselineTextures.insert(ObjectIdentifier(try #require(image).texture))
            image = nil
        }

        // Another renderer's (e.g. exporter's) frame: CPU done, GPU still running.
        let queue = try #require(device.makeCommandQueue())
        let raw = try #require(queue.makeCommandBuffer())
        let event = try #require(device.makeSharedEvent())
        defer { event.signaledValue = 1 }
        raw.encodeWaitForEvent(event, value: 1)
        let slowFrame = GraphCommandBuffer(commandBuffer: raw)
        let slowScope = try #require(slowFrame.beginTextureRecycling())
        slowFrame.endTextureRecycling(slowScope)
        slowFrame.commit()

        var stalledTextures = Set<ObjectIdentifier>()
        for _ in 0..<5 {
            var image: FabricImage? = try #require(unrelatedCache.newManagedImage(width: 4, height: 4, pixelFormat: .rgba8Unorm))
            stalledTextures.insert(ObjectIdentifier(try #require(image).texture))
            image = nil
        }
        let retained = slowScope.retirements.count

        event.signaledValue = 1
        raw.waitUntilCompleted()
        var afterTextures = Set<ObjectIdentifier>()
        for _ in 0..<5 {
            var image: FabricImage? = try #require(unrelatedCache.newManagedImage(width: 4, height: 4, pixelFormat: .rgba8Unorm))
            afterTextures.insert(ObjectIdentifier(try #require(image).texture))
            image = nil
        }
        print("REVIEW3 distinct textures: baseline=\(baselineTextures.count) whilePending=\(stalledTextures.count) after=\(afterTextures.count) retirementsHeldBySlowScope=\(retained)")
        #expect(baselineTextures.count == 1)
        #expect(stalledTextures.count == 1, "unrelated cache allocated \(stalledTextures.count) textures while another frame was in flight")
    }
}
