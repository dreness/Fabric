import Testing
import Foundation
import Metal
@testable import Fabric
import Satin

// MARK: - Helpers

private func makeCanvasContext() -> GraphCanvasContext? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    let context = Context(
        device: device,
        sampleCount: 1,
        colorPixelFormat: .bgra8Unorm,
        depthPixelFormat: .invalid,
        stencilPixelFormat: .invalid
    )
    return GraphCanvasContext(rootGraph: Graph(context: context))
}

private func addNode(to graph: Graph, offset: CGSize, selected: Bool = false) -> NumberBinaryOperator {
    let node = NumberBinaryOperator(context: graph.context)
    node.offset = offset
    graph.addNode(node)
    graph.viewModel(for: node).isSelected = selected
    return node
}

private func addNote(to graph: Graph, rect: CGRect) -> Note {
    let note = Note(note: "A note", rect: rect)
    graph.addNote(note)
    return note
}

// MARK: - Tests

@Suite("Graph canvas framing rect")
struct GraphCanvasFramingRectTests {

    @Test("An empty graph has nothing to frame")
    func emptyGraph() {
        guard let canvasContext = makeCanvasContext() else { return }

        #expect(canvasContext.graphRect(framing: .selection) == nil)
        #expect(canvasContext.graphRect(framing: .allContent) == nil)
    }

    @Test("Nothing selected frames nothing, even with content")
    func emptySelection() {
        guard let canvasContext = makeCanvasContext() else { return }
        let graph = canvasContext.currentGraph
        _ = addNode(to: graph, offset: .zero)
        _ = addNote(to: graph, rect: CGRect(x: 0, y: 0, width: 100, height: 100))

        #expect(canvasContext.graphRect(framing: .selection) == nil)
    }

    @Test("A single selected node's rect is centered on its offset")
    func singleNode() {
        guard let canvasContext = makeCanvasContext() else { return }
        let node = addNode(to: canvasContext.currentGraph, offset: CGSize(width: 400, height: -250), selected: true)

        let framed = canvasContext.graphRect(framing: .selection)

        #expect(framed?.size == node.nodeSize)
        #expect(framed?.center == CGPoint(x: 400, y: -250))
    }

    @Test("The selection spans the outer edges of selected nodes only")
    func selectedNodesOnly() {
        guard let canvasContext = makeCanvasContext() else { return }
        let graph = canvasContext.currentGraph
        let left = addNode(to: graph, offset: CGSize(width: -500, height: 0), selected: true)
        let right = addNode(to: graph, offset: CGSize(width: 800, height: 300), selected: true)
        _ = addNode(to: graph, offset: CGSize(width: 9000, height: 9000))
        _ = addNote(to: graph, rect: CGRect(x: -9000, y: -9000, width: 100, height: 100))

        let framed = canvasContext.graphRect(framing: .selection)

        #expect(framed?.minX == -500 - left.nodeSize.width / 2)
        #expect(framed?.maxX == 800 + right.nodeSize.width / 2)
        #expect(framed?.minY == -left.nodeSize.height / 2)
        #expect(framed?.maxY == 300 + right.nodeSize.height / 2)
    }

    @Test("A note's rect is already in graph coordinates")
    func singleNote() {
        guard let canvasContext = makeCanvasContext() else { return }
        let note = addNote(to: canvasContext.currentGraph, rect: CGRect(x: -300, y: 120, width: 500, height: 200))

        #expect(canvasContext.graphRect(framing: .allContent) == note.rect)
    }

    @Test("All content spans every node and note, selected or not")
    func allContent() {
        guard let canvasContext = makeCanvasContext() else { return }
        let graph = canvasContext.currentGraph
        let node = addNode(to: graph, offset: .zero)
        _ = addNote(to: graph, rect: CGRect(x: 600, y: -900, width: 400, height: 300))

        let framed = canvasContext.graphRect(framing: .allContent)

        #expect(framed?.minX == -node.nodeSize.width / 2)
        #expect(framed?.maxX == 1000)
        #expect(framed?.minY == -900)
        #expect(framed?.maxY == node.nodeSize.height / 2)
    }

    @Test("Frame availability agrees with whether there is a rect to frame")
    func hasContentMatchesGraphRect() {
        guard let canvasContext = makeCanvasContext() else { return }
        let graph = canvasContext.currentGraph

        func expectAgreement() {
            for scope in [GraphCanvasFramingScope.selection, .allContent] {
                #expect(canvasContext.hasContent(framing: scope) == (canvasContext.graphRect(framing: scope) != nil))
            }
        }

        expectAgreement()
        _ = addNote(to: graph, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        expectAgreement()
        let node = addNode(to: graph, offset: .zero)
        expectAgreement()
        graph.viewModel(for: node).isSelected = true
        expectAgreement()
        #expect(canvasContext.hasContent(framing: .selection))
    }

    @Test("Framing reads the subgraph being displayed, not the root")
    func currentGraphOnly() {
        guard let canvasContext = makeCanvasContext() else { return }
        let rootGraph = canvasContext.rootGraph
        _ = addNode(to: rootGraph, offset: CGSize(width: -9000, height: -9000))

        let subgraphNode = SubgraphNode(context: rootGraph.context)
        rootGraph.addNode(subgraphNode)
        canvasContext.enter(subgraphNode)
        let innerNote = addNote(to: subgraphNode.subGraph, rect: CGRect(x: 10, y: 20, width: 300, height: 400))

        #expect(canvasContext.graphRect(framing: .allContent) == innerNote.rect)
    }
}
