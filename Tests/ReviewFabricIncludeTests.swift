import Testing
import Foundation
import Metal
import Satin
@testable import Fabric

/// Review evidence for Fabric#431. Compiles on both trees; set FABRIC_TREE=pr|base.
/// Prints tagged lines: INCLUDEPROBE, ORDERPROBE, SHADERSWEEP.
@Suite("Review Fabric Include", .serialized)
struct ReviewFabricIncludeTests {

    private var tree: String { ProcessInfo.processInfo.environment["FABRIC_TREE"] ?? "unknown" }

    private static let pluginShaderSource = """
    #include "fabric/FabricImageTextureTransform.metal"

    kernel void pluginSample(texture2d<float, access::sample> image [[texture(0)]],
                             texture2d<float, access::write> output [[texture(1)]],
                             constant float4x4 *imageTransforms [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]])
    {
        constexpr sampler s(filter::linear);
        const float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
        output.write(image.sample(s, fabricTextureCoordinate(imageTransforms[0], uv)), gid);
    }
    """

    private func writePluginShader(under relativeDirectory: String, in base: URL) throws -> URL {
        let directory = base.appending(path: relativeDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shaderURL = directory.appending(path: "Plugin.metal")
        try Self.pluginShaderSource.write(to: shaderURL, atomically: true, encoding: .utf8)
        return shaderURL
    }

    private func parseResult(_ url: URL) -> (source: String?, error: String?) {
        do {
            return (try MetalFileCompiler(watch: false).parse(url), nil)
        } catch {
            return (nil, error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @Test("A plugin shader outside the bundle includes fabric/FabricImageTextureTransform.metal")
    func pluginIncludeProbe() throws {
        try PluginLoader.shared.loadAllPlugins()
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }

        let shaderURL = try writePluginShader(under: "MyPlugin/Shaders", in: base)
        let result = parseResult(shaderURL)
        var compiled = false
        if let source = result.source, let device = MTLCreateSystemDefaultDevice() {
            compiled = (try? device.makeLibrary(source: source, options: nil))?
                .makeFunction(name: "pluginSample") != nil
        }
        let roots = shaderIncludeRootURLs.map(\.lastPathComponent).joined(separator: ",")
        print("INCLUDEPROBE tree=\(tree) roots=[\(roots)] resolved=\(result.source != nil) compiled=\(compiled) error=\(result.error ?? "-")")
    }

    /// Host roots are matched first-in-list, not nearest-component. A plugin whose
    /// own path has a `lygia` component above it sends its `fabric/` include to the
    /// lygia root.
    @Test("fabric/ include from a path with a lygia ancestor")
    func includeRootOrderProbe() throws {
        try PluginLoader.shared.loadAllPlugins()
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }

        for directory in ["control/MyPlugin", "lygia-fork/MyPlugin", "lygia/MyPlugin", "fabric/MyPlugin"] {
            let result = parseResult(try writePluginShader(under: directory, in: base))
            print("ORDERPROBE tree=\(tree) dir=\(directory) resolved=\(result.source != nil) error=\(result.error.map { $0.components(separatedBy: base.lastPathComponent).last ?? $0 } ?? "-")")
        }
    }

    /// Every bundled shader that includes the helper still resolves its includes.
    @Test("Core shaders that include the helper still parse")
    func coreShaderSweep() throws {
        try PluginLoader.shared.loadAllPlugins()
        let lygiaRoot = try #require(shaderIncludeRootURLs.first(where: { $0.lastPathComponent == "lygia" }))
        let resourceRoot = lygiaRoot.deletingLastPathComponent().absoluteURL
        let device = try #require(MTLCreateSystemDefaultDevice())

        var files = 0, parsed = 0, compiledOK = 0, compileAttempts = 0
        var parseFailures: [String] = []
        for folder in ["Effects", "EffectsTwoChannel", "EffectsThreeChannel", "Shaders", "Compute", "Materials"] {
            let folderURL = resourceRoot.appending(path: folder)
            guard let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where ["metal", "msl"].contains(url.pathExtension) {
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      text.contains("#include") && text.contains("FabricImageTextureTransform.metal") else { continue }
                files += 1
                let result = parseResult(url)
                guard let source = result.source else {
                    parseFailures.append(url.path(percentEncoded: false).replacing(resourceRoot.path(percentEncoded: false), with: ""))
                    continue
                }
                parsed += 1
                if url.pathExtension == "metal" {
                    compileAttempts += 1
                    if (try? device.makeLibrary(source: source, options: nil)) != nil { compiledOK += 1 }
                }
            }
        }
        print("SHADERSWEEP tree=\(tree) includers=\(files) parsed=\(parsed) parseFail=\(parseFailures.count) rawCompileOK=\(compiledOK)/\(compileAttempts)")
        for failure in parseFailures { print("SHADERSWEEP tree=\(tree) parseFail \(failure)") }
        #expect(parseFailures.isEmpty)
    }

    /// Every registered image node builds its Satin pipeline.
    @Test("Every registered image node's shader compiles through Satin")
    func imageNodePipelineSweep() throws {
        try PluginLoader.shared.loadAllPlugins()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm,
                              depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)

        var nodes = 0, pipelines = 0
        var failures: [String] = []
        for wrapper in try NodeRegistry.shared.availableNodes where wrapper.nodeClass is BaseImageNode.Type {
            guard let node = (try? wrapper.initializeNode(context: context)) as? BaseImageNode else {
                failures.append("\(wrapper.nodeName) (init)")
                continue
            }
            nodes += 1
            if node.postMaterial.shader == nil { node.postMaterial.setup() }
            if node.postMaterial.shader?.getPipeline(renderContext: context, shadow: false) != nil {
                pipelines += 1
            } else {
                failures.append(wrapper.nodeName)
            }
        }
        print("PIPELINESWEEP tree=\(tree) imageNodes=\(nodes) pipelines=\(pipelines) failures=\(failures.count)")
        for failure in failures { print("PIPELINESWEEP tree=\(tree) fail \(failure)") }
    }
}
