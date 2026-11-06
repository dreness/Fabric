import Testing
import Foundation
import simd
@testable import Fabric

// Review evidence for Gradient Noise 3D. Prints NOISEBENCH lines; NOISEBENCH_RUNS sets the run count.
@Suite("Review Gradient Noise 3D")
struct ReviewGradientNoise3DTests
{
    static func spherePoints(_ count: Int) -> ContiguousArray<simd_float3>
    {
        ContiguousArray((0..<count).map { index in
            let angle = Float(index) * 2.399963
            let height = 1 - 2 * (Float(index) + 0.5) / Float(count)
            let ring = (1 - height * height).squareRoot()
            return simd_float3(ring * cos(angle), height, ring * sin(angle))
        })
    }

    @Test("A NaN position traps the process")
    func nanPositionTraps() async
    {
        await #expect(processExitsWith: .signal(SIGTRAP)) {
            let field = GradientNoise3DNode.makeField(frequency: 1, octaves: 4, persistence: 0.5, lacunarity: 2, seed: 0)
            _ = GradientNoise3DNode.sample(field, at: [simd_float3(.nan, 0, 0)], offset: .zero, amplitude: 1)
        }
    }

    @Test("An infinite Time traps the process")
    func infiniteTimeTraps() async
    {
        await #expect(processExitsWith: .signal(SIGTRAP)) {
            let field = GradientNoise3DNode.makeField(frequency: 1, octaves: 4, persistence: 0.5, lacunarity: 2, seed: 0)
            let offset = simd_float3(0, 0, 0.5) * Float.infinity
            _ = GradientNoise3DNode.sample(field, at: [simd_float3(1, 0, 0)], offset: offset, amplitude: 1)
        }
    }

    @Test("Octaves above the slider range from a connected inlet trap the process")
    func largeOctavesTrap() async
    {
        await #expect(processExitsWith: .signal(SIGTRAP)) {
            let field = GradientNoise3DNode.makeField(frequency: 1, octaves: 70, persistence: 0.5, lacunarity: 2, seed: 0)
            _ = GradientNoise3DNode.sample(field, at: [simd_float3(1, 0.5, 0.25)], offset: .zero, amplitude: 1)
        }
    }

    @Test("Through the node: a NaN in Positions traps on execute")
    func nanThroughNodeTraps() async
    {
        await #expect(processExitsWith: .signal(SIGTRAP)) {
            guard let harness = GraphExecutionTestHarness(renderWidth: 64, renderHeight: 64) else { return }
            let node = GradientNoise3DNode(context: harness.context)
            node.inputPositions.value = [simd_float3(0, .nan, 0)]
            try? harness.execute(node)
        }
    }

    @Test("Values stay in range at the slider extremes")
    func extremesInRange()
    {
        let points = Self.spherePoints(2000)
        for persistence: Float in [0, 0.5, 1]
        {
            let field = GradientNoise3DNode.makeField(frequency: 20, octaves: 8, persistence: persistence, lacunarity: 4, seed: 3)
            let values = GradientNoise3DNode.sample(field, at: points, offset: .zero, amplitude: 1)
            let peak = values.map(abs).max() ?? 0
            print("NOISERANGE persistence=\(persistence) peak=\(peak)")
            #expect(values.allSatisfy { $0.isFinite })
            #expect(peak <= 1.1)
        }
    }

    @Test("Changing Octaves or Seed alone re-sends a different array")
    func fieldSettingsResend() throws
    {
        guard let harness = GraphExecutionTestHarness(renderWidth: 64, renderHeight: 64) else { return }
        let node = GradientNoise3DNode(context: harness.context)
        node.inputPositions.value = Self.spherePoints(200)
        try harness.execute(node)
        let first = try #require(node.outputValues.value)

        node.markClean()
        node.outputValues.value = nil
        node.inputOctaves.value = 2
        try harness.execute(node)
        let fewerOctaves = try #require(node.outputValues.value)
        #expect(fewerOctaves != first)

        node.markClean()
        node.outputValues.value = nil
        node.inputSeed.value = 9
        try harness.execute(node)
        let reseeded = try #require(node.outputValues.value)
        #expect(reseeded != fewerOctaves)
    }

    @Test("NOISEBENCH: sample cost per frame")
    func benchmark()
    {
        let runs = Int(ProcessInfo.processInfo.environment["NOISEBENCH_RUNS"] ?? "") ?? 15
        let clock = ContinuousClock()
        for count in [1_000, 10_000, 50_000]
        {
            let points = Self.spherePoints(count)
            for octaves in [1, 4, 8]
            {
                let field = GradientNoise3DNode.makeField(frequency: 1.3, octaves: octaves, persistence: 0.5, lacunarity: 2, seed: 0)
                var timings: [Double] = []
                for run in 0..<runs
                {
                    let start = clock.now
                    let values = GradientNoise3DNode.sample(field, at: points, offset: simd_float3(0, 0, Float(run) * 0.01), amplitude: 1)
                    timings.append((clock.now - start) / .milliseconds(1))
                    #expect(values.count == count)
                }
                let median = timings.sorted()[timings.count / 2]
                print("NOISEBENCH points=\(count) octaves=\(octaves) median_ms=\(median.formatted(.number.precision(.fractionLength(3))))")
            }
        }
    }
}
