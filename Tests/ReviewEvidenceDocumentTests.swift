import Testing
import Foundation
import Metal
import simd
import Satin
@testable import Fabric

/// Builds the Iterator form of Glyph Carousel and writes it to FABRIC_EVIDENCE_OUT.
@Suite("Review: evidence documents", .serialized)
struct ReviewEvidenceDocumentTests {
    static let outputDirectory = URL(filePath: ProcessInfo.processInfo.environment["FABRIC_EVIDENCE_OUT"] ?? NSTemporaryDirectory())

    static func place(_ node: Node, _ x: Double, _ y: Double) { node.offset = CGSize(width: x, height: y) }

    @Test("Write Glyph Carousel (Iterator)")
    func writeIteratorCarousel() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm, depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
        let glyphs = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789&?!@#%*+=~$"
        let count = glyphs.count
        let radius: Float = 8

        let root = Graph(context: context)
        let iterator = IteratorNode(context: context)
        iterator.inputIteratonCount.value = count
        let inner = iterator.subGraph

        let info = IteratorInfoNode(context: context)
        let time = CurrentTimeNode(context: context)
        let expression = MathExpressionNode(context: context)
        expression.stringExpression = """
        in t: float;
        in p: float;
        let i = round(p * (count - 1));
        let angle = t * spin + i * tau / count;
        let half = (pi - angle) / 2;
        out from = i;
        out to = i + 1;
        out position = vec3(-sin(angle) * radius, bob * sin(t * 1.7 + i * 1.3), cos(angle) * radius);
        out orientation = vec4(0, sin(half), 0, cos(half));
        out size3 = vec3(size, size, size * depth);
        out color = mix(vec4(1, 0.7, 0.15, 1), vec4(0.95, 0.95, 0.92, 1), mod(i, 2))
        """
        func set(_ name: String, _ value: Float) { (expression.port(named: name) as ParameterPort<Float>).value = value }
        set("count", Float(count)); set("spin", 0.35); set("radius", radius); set("bob", 0.15); set("size", 0.6); set("depth", 0.35)

        let from = NumberRoundNode(context: context)
        let to = NumberRoundNode(context: context)
        let range = StringRangeNode(context: context)
        range.inputPort.value = glyphs
        let text = ExtrudedTextGeometryNode(context: context)
        text.inputFont.value = "Avenir Next"
        let material = StandardMaterialNode(context: context)
        material.inputRoughness.value = 0.3
        material.inputMetallic.value = 0
        let mesh = MeshNode(context: context)

        for (index, node) in [info, time, expression, from, to, range, text, material, mesh].enumerated() {
            inner.addNode(node); Self.place(node, Double(index % 3) * 320, Double(index / 3) * 260)
        }
        inner.connect(info.outputProgress, to: expression.port(named: "p") as ParameterPort<Float>)
        inner.connect(time.outputNumber, to: expression.port(named: "t") as ParameterPort<Float>)
        inner.connect(expression.port(named: "from") as NodePort<Float>, to: from.inputNumber)
        inner.connect(expression.port(named: "to") as NodePort<Float>, to: to.inputNumber)
        inner.connect(from.outputNumber, to: range.inputRangeFrom)
        inner.connect(to.outputNumber, to: range.inputRangeTo)
        inner.connect(range.outputPort, to: text.inputText)
        inner.connect(expression.port(named: "color") as NodePort<simd_float4>, to: material.inputBaseColor)
        inner.connect(text.outputGeometry, to: mesh.inputGeometry)
        inner.connect(material.outputMaterial, to: mesh.inputMaterial)
        inner.connect(expression.port(named: "position") as NodePort<simd_float3>, to: mesh.inputPosition)
        inner.connect(expression.port(named: "orientation") as NodePort<simd_float4>, to: mesh.inputOrientation)
        inner.connect(expression.port(named: "size3") as NodePort<simd_float3>, to: mesh.inputScale)

        let floorGeometry = BoxGeometryNode(context: context)
        floorGeometry.inputWidthParam.value = 12; floorGeometry.inputHeightParam.value = 0.05; floorGeometry.inputDepthParam.value = 6
        let floorMaterial = StandardMaterialNode(context: context)
        floorMaterial.inputBaseColor.value = [0.18, 0.2, 0.24, 1]; floorMaterial.inputRoughness.value = 0.9; floorMaterial.inputMetallic.value = 0
        let floor = MeshNode(context: context)
        floor.inputPosition.value = [0, -0.6, radius]
        let point = PointLightNode(context: context)
        point.inputPosition.value = [1.5, 3, radius - 1.5]; point.inputLookAt.value = [0, 0, radius]
        point.inputColor.value = [1, 0.95, 0.85]; point.inputIntensity.value = 30; point.inputRadius.value = 16
        let directional = DirectionalLightNode(context: context)
        directional.inputPosition.value = [-2, 4, radius - 3]; directional.inputLookAt.value = [0, 0, radius]
        directional.inputColor.value = [0.5, 0.6, 1]; directional.inputIntensity.value = 0.6
        let camera = PerspectiveCameraNode(context: context)
        camera.inputPosition.value = [0, 0.35, radius - 2.6]
        camera.inputOrientation.value = [0, 1, 0, 0]

        for (index, node) in [iterator, floorGeometry, floorMaterial, floor, point, directional, camera].enumerated() {
            root.addNode(node); Self.place(node, Double(index % 3) * 320, Double(index / 3) * 260)
        }
        root.connect(floorGeometry.outputGeometry, to: floor.inputGeometry)
        root.connect(floorMaterial.outputMaterial, to: floor.inputMaterial)

        root.addNote(Note(note: """
        # Glyph Carousel (Iterator)

        One **Iterator** runs \(count) times. Inside, **Iterator Info** picks a character out of the glyph string with **String Range**, **3D Text Geometry** meshes it, and a **Math Expression** places it on a ring of **radius** world units and alternates its colour. The camera stands inside the ring near the rim looking outward, so about five glyphs are in view while the rest slide past off screen. Each glyph casts a shadow onto the floor.

        **spin** sets the turning rate, **bob** floats each glyph, **size** scales them, **depth** flattens the extrusion.
        """, rect: CGRect(x: -40, y: -560, width: 680, height: 420)))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        let url = Self.outputDirectory.appending(path: "Glyph Carousel Iterator.fabric")
        try encoder.encode(root).write(to: url)
        print("EVIDENCE wrote \(url.path) rootNodes=\(root.nodes.count) innerNodes=\(inner.nodes.count)")
    }
}
