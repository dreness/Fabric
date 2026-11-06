import Testing
import simd
@testable import Fabric

@Suite("Gradient Noise 3D")
struct GradientNoise3DNodeTests
{
    private let positions: ContiguousArray<simd_float3> = ContiguousArray((0..<500).map { index in
        let angle = Float(index) * 2.399963
        let height = 1 - 2 * (Float(index) + 0.5) / 500
        let ring = (1 - height * height).squareRoot()
        return simd_float3(ring * cos(angle), height, ring * sin(angle)) * 1.7
    })

    private func values(seed: Int = 0, offset: simd_float3 = .zero, amplitude: Float = 1,
                        at points: ContiguousArray<simd_float3>? = nil) -> ContiguousArray<Float>
    {
        let field = GradientNoise3DNode.makeField(frequency: 1.3, octaves: 4, persistence: 0.5, lacunarity: 2, seed: seed)
        return GradientNoise3DNode.sample(field, at: points ?? positions, offset: offset, amplitude: amplitude)
    }

    @Test("One value per position, the same for the same seed and different for another")
    func seedIsRepeatable()
    {
        let first = values(seed: 7)
        #expect(first.count == positions.count)
        #expect(first == values(seed: 7))
        #expect(first != values(seed: 8))
    }

    @Test("Values vary, stay within Amplitude, and scale with it")
    func rangeAndAmplitude()
    {
        let unit = values()
        let spread = (unit.max() ?? 0) - (unit.min() ?? 0)
        #expect(spread > 0.3, "Field is not flat")
        #expect(unit.allSatisfy { abs($0) <= 1.05 })
        let doubled = values(amplitude: 2)
        #expect(zip(unit, doubled).allSatisfy { abs($1 - 2 * $0) < 1e-5 })
    }

    @Test("Nearby points give nearby values")
    func fieldIsSmooth()
    {
        let nudged = ContiguousArray(positions.map { $0 + simd_float3(1e-3, -1e-3, 1e-3) })
        let base = values()
        let moved = values(at: nudged)
        #expect(zip(base, moved).allSatisfy { abs($0 - $1) < 0.02 })
    }

    @Test("Drift x Time samples the field at the shifted positions")
    func offsetShiftsField()
    {
        let offset = simd_float3(0.4, -1.1, 2.5)
        let shifted = ContiguousArray(positions.map { $0 + offset })
        #expect(values(offset: offset) == values(at: shifted))
    }

    @Test("Executing the node sends one value per position, then follows Time")
    func nodeSendsValues() throws
    {
        guard let harness = GraphExecutionTestHarness(renderWidth: 64, renderHeight: 64) else { return }
        let node = GradientNoise3DNode(context: harness.context)
        node.inputPositions.value = positions
        try harness.execute(node)
        let atRest = try #require(node.outputValues.value)
        let defaultField = GradientNoise3DNode.makeField(frequency: 1, octaves: 4, persistence: 0.5, lacunarity: 2, seed: 0)
        #expect(atRest == GradientNoise3DNode.sample(defaultField, at: positions, offset: .zero, amplitude: 1))

        node.markClean()
        node.outputValues.value = nil
        try harness.execute(node)
        #expect(node.outputValues.value == nil, "No input changed, so nothing is sent")

        node.inputTime.value = 2
        try harness.execute(node)
        let moved = try #require(node.outputValues.value)
        #expect(moved != atRest)
    }
}
