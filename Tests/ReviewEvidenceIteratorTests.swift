import Testing
import Foundation
import Metal
import simd
import Satin
@testable import Fabric

/// Iterator state that the frame-contract PR says it fixes: per-iteration material and geometry
/// changes, and removing a node from an Iterator's subgraph. Identical source on base and PR.
@Suite("Review: iterator state", .serialized)
struct ReviewEvidenceIteratorTests {
    typealias Evidence = ReviewEvidenceTests

    /// Sets its color port per iteration, as an Iterator Info -> Color connection would.
    final class IterationColoredMaterialNode: BasicColorMaterialNode {
        static let colors: [simd_float4] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1]]
        override public func execute(renderer: GraphRenderer, executionInfo: GraphExecutionInfo,
                                     renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) throws {
            let iteration = executionInfo.iterationInfo?.currentIteration ?? 0
            inputColor.value = Self.colors[min(iteration, Self.colors.count - 1)]
            try super.execute(renderer: renderer, executionInfo: executionInfo, renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
        }
    }

    /// Sets its width port per iteration.
    final class IterationSizedBoxNode: BoxGeometryNode {
        static let widths: [Float] = [0.4, 1.0, 1.6]
        override public func execute(renderer: GraphRenderer, executionInfo: GraphExecutionInfo,
                                     renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) throws {
            let iteration = executionInfo.iterationInfo?.currentIteration ?? 0
            inputWidthParam.value = Self.widths[min(iteration, Self.widths.count - 1)]
            try super.execute(renderer: renderer, executionInfo: executionInfo, renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
        }
    }

    struct Run: Codable { var start: Int; var width: Int; var color: [Int] }

    /// Lit runs on the middle row with the color at each run's center.
    static func runsOnMiddleRow(_ bgra: [UInt8], width: Int, height: Int) -> [Run] {
        let row = height / 2
        let background = Array(bgra[0..<4])
        var runs: [Run] = []
        var start: Int?
        func close(_ end: Int) {
            guard let s = start else { return }
            let center = ((s + end) / 2 + row * width) * 4
            runs.append(Run(start: s, width: end - s, color: [Int(bgra[center + 2]), Int(bgra[center + 1]), Int(bgra[center])]))
            start = nil
        }
        for x in 0..<width {
            let index = (row * width + x) * 4
            let lit = Array(bgra[index..<index + 4]) != background
            if lit, start == nil { start = x }
            if !lit { close(x) }
        }
        close(width)
        return runs
    }

    @Test("Per-iteration material color, geometry size, and node removal inside an Iterator")
    func iteratorState() throws {
        let harness = try #require(GraphExecutionTestHarness(renderWidth: 384, renderHeight: 128))
        let context = harness.context
        let graph = Graph(context: context)
        let iterator = IteratorNode(context: context)
        iterator.inputIteratonCount.value = 3
        let geometry = IterationSizedBoxNode(context: context)
        let material = IterationColoredMaterialNode(context: context)
        let mesh = Evidence.IterationPlacedMeshNode(context: context)
        mesh.offsets = Evidence.offsets
        mesh.inputScale.value = .init(repeating: 0.3)
        let sub = iterator.subGraph
        sub.addNode(geometry); sub.addNode(material); sub.addNode(mesh)
        sub.connect(geometry.outputGeometry, to: mesh.inputGeometry)
        sub.connect(material.outputMaterial, to: mesh.inputMaterial)
        graph.addNode(iterator)

        try harness.graphRenderer(for: graph).startExecution()
        defer { try? harness.graphRenderer(for: graph).stopExecution() }

        var results: [String: Any] = ["tree": Evidence.tree]
        for frame in 0..<4 {
            if frame == 3 { sub.delete(node: mesh) }
            let texture = try harness.execute(graph: graph, executionInfo: harness.makeExecutionInfo(frameNumber: frame), drawScene: true)
            guard frame >= 2 else { continue }
            let pixels = try Evidence.readPixels(texture, device: context.device, queue: harness.renderer.commandQueue)
            let name = frame == 2 ? "iterator-state" : "iterator-after-removal"
            try Evidence.writePNG(pixels, width: 384, height: 128, name: name)
            let runs = Self.runsOnMiddleRow(pixels, width: 384, height: 128)
            results[name] = runs.map { ["start": $0.start, "width": $0.width, "color": $0.color] }
            print("EVIDENCE \(Evidence.tree) \(name): shapes=\(runs.count) widths=\(runs.map(\.width)) colors=\(runs.map(\.color))")
        }
        print("EVIDENCE \(Evidence.tree) expected: frame 2 has 3 shapes, 3 distinct widths, 3 distinct colors; frame 3 has 0 shapes")
        let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        try data.write(to: Evidence.outputDirectory.appending(path: "iterator-state.\(Evidence.tree).json"))
    }
}
