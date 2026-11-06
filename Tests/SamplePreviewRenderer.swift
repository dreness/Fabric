import Testing
import Foundation
import Metal
@testable import Fabric
import Satin

// Renders <PREVIEW_INPUT>/<name>.fabric to PNGs at t=1, 3, 6s (or PREVIEW_TIMES) and prints ms/frame. Disabled unless PREVIEW_SAMPLES is set.
//   PREVIEW_SAMPLES="Genuary/Genuary 1,2 - Animation/Sea Urchin" [PREVIEW_TIMES="1,2.5"] [PREVIEW_INPUT=/some/dir] [PREVIEW_OUTPUT=/some/dir] swift test --filter SamplePreviewRenderer
// Input defaults to the Fabric-Samples submodule's Samples folder, so names are paths relative to it. Output defaults to $TMPDIR/FabricSamplePreviews.
enum SamplePreviewConfiguration
{
    static var inputDirectory: URL
    {
        if let path = ProcessInfo.processInfo.environment["PREVIEW_INPUT"], !path.isEmpty
        {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return FabricSampleCatalog.samplesRootURL
    }

    static var outputDirectory: URL
    {
        if let path = ProcessInfo.processInfo.environment["PREVIEW_OUTPUT"], !path.isEmpty
        {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return URL.temporaryDirectory.appending(path: "FabricSamplePreviews", directoryHint: .isDirectory)
    }

    static var sampleNames: [String]
    {
        let raw = ProcessInfo.processInfo.environment["PREVIEW_SAMPLES"] ?? ""
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static var captureTimes: [Double]
    {
        (ProcessInfo.processInfo.environment["PREVIEW_TIMES"] ?? "1,3,6")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.sorted()
    }
}

@MainActor
@Suite("Sample Preview Renderer", .enabled(if: !SamplePreviewConfiguration.sampleNames.isEmpty, "Set PREVIEW_SAMPLES to the sample names to render"))
struct SamplePreviewRenderer
{
    @Test("Render previews")
    func render() throws
    {
        let captureTimes = SamplePreviewConfiguration.captureTimes
        try #require(captureTimes.first.map { $0 >= 0 } ?? false, "PREVIEW_TIMES holds no non-negative times")
        for name in SamplePreviewConfiguration.sampleNames
        {
            try renderSample(name, at: captureTimes)
        }
    }

    private func renderSample(_ name: String, at captureTimes: [Double]) throws
    {
        let context = try FabricSampleTestSupport.makeContext()
        let url = SamplePreviewConfiguration.inputDirectory.appending(path: "\(name).fabric")
        let decoder = JSONDecoder()
        decoder.context = DecoderContext(documentContext: context)
        let graph = try decoder.decode(Graph.self, from: try Data(contentsOf: url))

        let width = 960, height = 540
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: context.colorPixelFormat, width: width, height: height, mipmapped: false)
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        let color = try #require(context.device.makeTexture(descriptor: colorDescriptor))
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: context.depthPixelFormat, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        let depth = try #require(context.device.makeTexture(descriptor: depthDescriptor))

        // Same context as the editor and the sample suite; the PNGs keep its transparent background.
        let renderer = GraphExportRenderer(graph: graph, context: context, size: (width, height))
        try renderer.start()
        defer { try? renderer.finish() }

        try FileManager.default.createDirectory(at: SamplePreviewConfiguration.outputDirectory, withIntermediateDirectories: true)

        // Frames run sequentially from t=0 so stateful nodes (integrators, feedback) see real history.
        let framesPerSecond = 30.0
        var frame = 0
        var elapsedSeconds: Double = 0
        let clock = ContinuousClock()
        for captureTime in captureTimes
        {
            while Double(frame) / framesPerSecond <= captureTime
            {
                let start = clock.now
                try renderer.renderFrame(into: color, depthTexture: depth, time: Double(frame) / framesPerSecond)
                elapsedSeconds += (clock.now - start) / .seconds(1)
                frame += 1
            }
            let image = try FabricSampleTestSupport.makeImage(from: color, context: context)
            let fileName = "\(url.deletingPathExtension().lastPathComponent) t\(captureTime.formatted()).png"
            try FabricSampleTestSupport.writePNG(image, to: SamplePreviewConfiguration.outputDirectory.appending(path: fileName))
        }
        let millisecondsPerFrame = (elapsedSeconds / Double(frame) * 1000).formatted(.number.precision(.fractionLength(2)))
        print("PREVIEW \(name): \(frame) frames, \(millisecondsPerFrame) ms/frame -> \(SamplePreviewConfiguration.outputDirectory.path())")
    }
}
