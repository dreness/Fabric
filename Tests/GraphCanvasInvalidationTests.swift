// NSHostingView hosts the canvas to count its re-evaluations; AppKit-only.
#if canImport(AppKit)
import Testing
import AppKit
import SwiftUI
import Metal
@testable import Fabric
import Satin

@MainActor
private final class EvaluationCounter
{
    var count = 0
}

/// Reads `centerGraphCanvas` as `GraphCanvas` does. The zoom modifier hands it a new
/// closure on every body evaluation, so this counts how often the canvas is re-evaluated.
private struct CenterGraphCanvasReader: View
{
    @Environment(\.centerGraphCanvas) private var centerGraphCanvas
    let counter: EvaluationCounter

    var body: some View
    {
        counter.count += 1
        return Color.clear
    }
}

/// The editor's canvas hosting, as in ContentView.
private struct HostedCanvas<Canvas: View>: View
{
    let editingContext: GraphCanvasContext
    @ViewBuilder let canvas: () -> Canvas
    @State private var scrollPosition = ScrollPosition()

    var body: some View
    {
        let canvasSize = editingContext.canvasSize

        ScrollView([.horizontal, .vertical])
        {
            canvas()
                .frame(width: canvasSize.width, height: canvasSize.height)
                .modifier(GraphCanvasZoomModifier(editingContext: editingContext,
                                                  canvasSize: canvasSize,
                                                  scrollPosition: $scrollPosition))
        }
        .defaultScrollAnchor(.center)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ScrollGeometry.self) { geometry in
            geometry
        } action: { _, newGeometry in
            editingContext.currentScrollGeometry = newGeometry
        }
    }
}

private struct RealGraphCanvas: View
{
    let editingContext: GraphCanvasContext
    @FocusState private var focus: FabricEditorFocusTarget?

    var body: some View
    {
        GraphCanvas(editingContext: editingContext, focus: $focus, canvasSize: editingContext.canvasSize)
    }
}

@MainActor
private final class Harness
{
    let editingContext: GraphCanvasContext
    let counter = EvaluationCounter()
    private let window: NSWindow
    private let hostingView: NSView

    init?(realCanvas: Bool = false)
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let context = Context(device: device,
                              sampleCount: 1,
                              colorPixelFormat: .bgra8Unorm,
                              depthPixelFormat: .invalid,
                              stencilPixelFormat: .invalid)
        let editingContext = GraphCanvasContext(rootGraph: Graph(context: context))
        editingContext.canvasSize = CGSize(width: 10_000, height: 10_000)
        self.editingContext = editingContext

        let counter = counter
        hostingView = realCanvas
            ? NSHostingView(rootView: HostedCanvas(editingContext: editingContext) { RealGraphCanvas(editingContext: editingContext) })
            : NSHostingView(rootView: HostedCanvas(editingContext: editingContext) { CenterGraphCanvasReader(counter: counter) })
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 900),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFrontRegardless()
        settle(passes: 5)
    }

    deinit
    {
        MainActor.assumeIsolated { window.close() }
    }

    var graph: Graph { editingContext.currentGraph }

    func addNodes(_ count: Int) -> [Node]
    {
        let nodes = (0..<count).map { index in
            let node = NumberBinaryOperator(context: graph.context)
            node.offset = CGSize(width: (index % 20) * 200 - 2000, height: (index / 20) * 200 - 1500)
            return node
        }
        nodes.forEach(graph.addNode)
        settle(passes: 5)
        return nodes
    }

    /// Lets SwiftUI apply pending observation and scroll updates.
    func settle(passes: Int = 1)
    {
        for _ in 0..<passes
        {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            hostingView.layoutSubtreeIfNeeded()
        }
    }

    var scrollView: NSScrollView?
    {
        func search(_ view: NSView) -> NSScrollView?
        {
            if let scrollView = view as? NSScrollView { return scrollView }
            return view.subviews.lazy.compactMap(search).first
        }
        return search(hostingView)
    }
}

/// Edits that happen every frame of an interaction must not re-evaluate the whole canvas.
@Suite("Graph canvas invalidation", .serialized)
@MainActor
struct GraphCanvasInvalidationTests
{
    @Test func scrollingDoesNotReevaluateTheCanvas() throws
    {
        guard let harness = Harness() else { return }
        let scrollView = try #require(harness.scrollView)
        let start = scrollView.contentView.bounds.origin
        harness.counter.count = 0

        for step in 1...20
        {
            scrollView.contentView.scroll(to: CGPoint(x: start.x + CGFloat(step) * 10, y: start.y + CGFloat(step) * 5))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            harness.settle()
        }

        #expect(harness.editingContext.currentScrollGeometry.contentOffset.x > start.x)
        #expect(harness.counter.count == 0)
    }

    @Test func selectingNodesDoesNotReevaluateTheCanvas()
    {
        guard let harness = Harness() else { return }
        let nodes = harness.addNodes(20)
        harness.counter.count = 0

        // A marquee drag selects a node at a time.
        for node in nodes
        {
            harness.graph.viewModel(for: node).isSelected = true
            harness.settle()
        }

        #expect(harness.counter.count == 0)
    }

    @Test func draggingNodesDoesNotReevaluateTheCanvas()
    {
        guard let harness = Harness() else { return }
        let nodes = harness.addNodes(5)
        harness.counter.count = 0

        for step in 1...20
        {
            nodes.forEach { $0.offset.width += CGFloat(step) }
            harness.settle()
        }

        #expect(harness.counter.count == 0)
    }

    @Test func addingNodesAndNotesDoesNotReevaluateTheCanvas()
    {
        guard let harness = Harness() else { return }
        harness.counter.count = 0

        _ = harness.addNodes(3)
        harness.graph.addNote(Note(note: "A note", rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        harness.settle(passes: 5)

        #expect(harness.counter.count == 0)
    }

    @Test func zoomingReevaluatesTheCanvas()
    {
        guard let harness = Harness() else { return }
        harness.counter.count = 0

        harness.editingContext.canvasZoomTransform = GraphCanvasZoomTransform(scale: 1.5)
        harness.settle(passes: 5)

        #expect(harness.counter.count > 0)
    }

    /// `FABRIC_BENCHMARKS=1 swift test --filter GraphCanvasInvalidationTests/selectionBenchmark`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FABRIC_BENCHMARKS"] != nil))
    func selectionBenchmark()
    {
        guard let harness = Harness(realCanvas: true) else { return }
        let nodes = harness.addNodes(300)

        let elapsed = ContinuousClock().measure {
            for node in nodes
            {
                harness.graph.viewModel(for: node).isSelected = true
                harness.settle()
            }
        }
        print("Selecting \(nodes.count) nodes one at a time with the real canvas: \(elapsed / nodes.count) per change")
    }
}
#endif
