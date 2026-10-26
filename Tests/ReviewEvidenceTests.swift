import Testing
import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Satin
@testable import Fabric

/// User-facing evidence for the frame-contract PRs. Identical source compiled against base and PR.
/// FABRIC_TREE labels the output; FABRIC_SAMPLES_DIR holds .fabric documents; FABRIC_EVIDENCE_OUT receives PNGs and JSON.
@Suite("Review: evidence", .serialized)
struct ReviewEvidenceTests {
    static let tree = ProcessInfo.processInfo.environment["FABRIC_TREE"] ?? "unknown"
    static let samplesDirectory = URL(filePath: ProcessInfo.processInfo.environment["FABRIC_SAMPLES_DIR"] ?? "")
    static let outputDirectory = URL(filePath: ProcessInfo.processInfo.environment["FABRIC_EVIDENCE_OUT"] ?? NSTemporaryDirectory())

    // MARK: helpers

    static func threadCPUNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    static func readPixels(_ texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
        descriptor.storageMode = .shared
        guard let readback = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else { throw GraphExecutionTestFailure("readback setup failed") }
        blit.copy(from: texture, to: readback)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress {
                readback.getBytes(base, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            }
        }
        return bytes
    }

    static func writePNG(_ bgra: [UInt8], width: Int, height: Int, name: String) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appending(path: "\(name).\(tree).png")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: colorSpace, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw GraphExecutionTestFailure("png encode failed") }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        print("EVIDENCE wrote \(url.path)")
    }

    /// Pixels that differ from the top-left (background) pixel.
    static func litPixels(_ bgra: [UInt8]) -> Int {
        guard bgra.count >= 4 else { return 0 }
        let background = Array(bgra[0..<4])
        var count = 0
        for index in stride(from: 0, to: bgra.count, by: 4) where Array(bgra[index..<index + 4]) != background { count += 1 }
        return count
    }

    /// Distinct runs of lit pixels along the middle row: a rough count of visible shapes side by side.
    static func shapesOnMiddleRow(_ bgra: [UInt8], width: Int, height: Int) -> Int {
        let row = height / 2
        let background = Array(bgra[0..<4])
        var runs = 0, inside = false
        for x in 0..<width {
            let index = (row * width + x) * 4
            let lit = Array(bgra[index..<index + 4]) != background
            if lit && !inside { runs += 1 }
            inside = lit
        }
        return runs
    }

    final class IterationPlacedMeshNode: MeshNode {
        var offsets: [Float] = []
        override public func execute(renderer: GraphRenderer, executionInfo: GraphExecutionInfo,
                                     renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) throws {
            try super.execute(renderer: renderer, executionInfo: executionInfo, renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
            guard !offsets.isEmpty else { return }
            let iteration = executionInfo.iterationInfo?.currentIteration ?? 0
            object?.position = [offsets[min(iteration, offsets.count - 1)], 0, 0]
        }
    }

    static let offsets: [Float] = [-0.6, 0, 0.6]

    static func addIteratedMesh(to graph: Graph, context: Context) {
        let geometry = BoxGeometryNode(context: context)
        let material = BasicColorMaterialNode(context: context)
        let mesh = IterationPlacedMeshNode(context: context)
        mesh.offsets = offsets
        mesh.inputScale.value = .init(repeating: 0.3)
        graph.addNode(geometry); graph.addNode(material); graph.addNode(mesh)
        graph.connect(geometry.outputGeometry, to: mesh.inputGeometry)
        graph.connect(material.outputMaterial, to: mesh.inputMaterial)
    }

    // MARK: Iterator evidence

    @Test("Iterator at root and inside Render to Image")
    func iteratorPlacements() throws {
        let harness = try #require(GraphExecutionTestHarness(renderWidth: 384, renderHeight: 128))
        let context = harness.context

        let rootGraph = Graph(context: context)
        let rootIterator = IteratorNode(context: context)
        rootIterator.inputIteratonCount.value = 3
        Self.addIteratedMesh(to: rootIterator.subGraph, context: context)
        rootGraph.addNode(rootIterator)

        let inner = Graph(context: context)
        let innerIterator = IteratorNode(context: context)
        innerIterator.inputIteratonCount.value = 3
        Self.addIteratedMesh(to: innerIterator.subGraph, context: context)
        inner.addNode(innerIterator)
        let imageNode = DeferredSubgraphNode(context: context, subGraph: inner)
        imageNode.inputWidth.value = 384
        imageNode.inputHeight.value = 128
        let imageGraph = Graph(context: context)
        imageGraph.addNode(imageNode)

        for graph in [rootGraph, imageGraph] { try harness.graphRenderer(for: graph).startExecution() }
        defer { for graph in [rootGraph, imageGraph] { try? harness.graphRenderer(for: graph).stopExecution() } }

        var results: [String: Int] = [:]
        for frame in 0..<3 {
            let rootTexture = try harness.execute(graph: rootGraph, executionInfo: harness.makeExecutionInfo(frameNumber: frame), drawScene: true)
            try harness.render(graph: imageGraph, executionInfo: harness.makeExecutionInfo(frameNumber: frame))
            if frame == 2 {
                let rootPixels = try Self.readPixels(rootTexture, device: context.device, queue: harness.renderer.commandQueue)
                try Self.writePNG(rootPixels, width: 384, height: 128, name: "iterator-root")
                results["iterator-root"] = Self.shapesOnMiddleRow(rootPixels, width: 384, height: 128)
                let image = try #require(imageNode.outputColorTexture.value)
                let imagePixels = try Self.readPixels(image.texture, device: context.device, queue: harness.renderer.commandQueue)
                try Self.writePNG(imagePixels, width: 384, height: 128, name: "iterator-in-render-to-image")
                results["iterator-in-render-to-image"] = Self.shapesOnMiddleRow(imagePixels, width: 384, height: 128)
            }
        }
        print("EVIDENCE \(Self.tree) shapes: \(results) (expected 3 each)")
        let data = try JSONSerialization.data(withJSONObject: ["tree": Self.tree, "shapes": results])
        try data.write(to: Self.outputDirectory.appending(path: "iterator.\(Self.tree).json"))
    }

    // MARK: Sample benchmark

    struct SampleResult: Codable {
        var name: String
        var nodes: Int
        var frames: Int
        var cpuMillisecondsPerFrameMedian: Double
        var cpuMillisecondsPerFrameMean: Double
        var gpuMillisecondsPerFrameMedian: Double
        var wallMillisecondsPerFrameMean: Double
        var error: String?
    }

    @Test("Render the sample documents and time the CPU per frame")
    func sampleBenchmark() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.samplesDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "fabric" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        print("EVIDENCE \(Self.tree) benchmarking \(files.count) documents from \(Self.samplesDirectory.path)")
        let width = 1920, height = 1080
        let warmupFrames = 30, measuredFrames = 240
        var results: [SampleResult] = []

        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            var result = SampleResult(name: name, nodes: 0, frames: 0, cpuMillisecondsPerFrameMedian: 0, cpuMillisecondsPerFrameMean: 0, gpuMillisecondsPerFrameMedian: 0, wallMillisecondsPerFrameMean: 0)
            do {
                let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm, depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
                let decoder = JSONDecoder()
                decoder.context = DecoderContext(documentContext: context)
                let graph = try decoder.decode(Graph.self, from: Data(contentsOf: file))
                result.nodes = graph.nodes.count
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

                let inFlight = DispatchSemaphore(value: 3)
                var cpuSamples: [Double] = []
                var wallSamples: [Double] = []
                var gpuSamples: [Double] = []
                let gpuLock = NSLock()
                let start = Date()
                for frame in 0..<(warmupFrames + measuredFrames) {
                    inFlight.wait()
                    let time = Double(frame) / 60
                    let info = GraphExecutionInfo(timing: GraphExecutionTiming(time: time, deltaTime: 1.0 / 60, displayTime: time, systemTime: time, hostMediaTime: time, frameNumber: frame), iterationInfo: nil, eventInfo: nil)
                    let cpuBefore = Self.threadCPUNanoseconds()
                    let wallBefore = DispatchTime.now().uptimeNanoseconds
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
                    let cpu = Double(Self.threadCPUNanoseconds() - cpuBefore) / 1e6
                    let wall = Double(DispatchTime.now().uptimeNanoseconds - wallBefore) / 1e6
                    if frame >= warmupFrames { cpuSamples.append(cpu); wallSamples.append(wall) }
                    if frame == warmupFrames + measuredFrames - 1 {
                        commands.waitUntilCompleted()
                        let pixels = try Self.readPixels(target, device: device, queue: renderer.commandQueue)
                        try Self.writePNG(pixels, width: width, height: height, name: "sample-\(name.replacing(" ", with: "-"))")
                    }
                }
                for _ in 0..<3 { inFlight.wait() }
                for _ in 0..<3 { inFlight.signal() }
                result.frames = cpuSamples.count
                result.cpuMillisecondsPerFrameMedian = cpuSamples.sorted()[cpuSamples.count / 2]
                result.cpuMillisecondsPerFrameMean = cpuSamples.reduce(0, +) / Double(cpuSamples.count)
                result.wallMillisecondsPerFrameMean = wallSamples.reduce(0, +) / Double(wallSamples.count)
                let gpuSorted = gpuLock.withLock { gpuSamples.sorted() }
                result.gpuMillisecondsPerFrameMedian = gpuSorted.isEmpty ? 0 : gpuSorted[gpuSorted.count / 2]
            } catch {
                result.error = "\(error)"
            }
            print("EVIDENCE \(Self.tree) \(name): nodes=\(result.nodes) cpu median \(result.cpuMillisecondsPerFrameMedian) ms, mean \(result.cpuMillisecondsPerFrameMean) ms, gpu median \(result.gpuMillisecondsPerFrameMedian) ms, wall \(result.wallMillisecondsPerFrameMean) ms \(result.error ?? "")")
            results.append(result)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        try encoder.encode(results).write(to: Self.outputDirectory.appending(path: "benchmark.\(Self.tree).json"))
    }
}
