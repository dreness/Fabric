import Testing
import Foundation
import Metal
import SwiftUI
@testable import Fabric
import Satin

/// Values measured from the running editor on macOS 27: a 200pt sidebar and a
/// 250.5pt inspector overlay a 1314pt-wide scroll container, which reports a
/// 863.5pt container size and a content offset at its physical leading edge.
@MainActor
struct GraphCanvasScrollViewportTests
{
    private let contentOffset = CGPoint(x: 3930.5, y: 4427.5)
    private let containerSize = CGSize(width: 863.5, height: 793)
    private let contentSize = CGSize(width: 10_000, height: 10_000)

    private func geometry(insets: EdgeInsets) -> ScrollGeometry
    {
        ScrollGeometry(contentOffset: contentOffset,
                       contentSize: contentSize,
                       contentInsets: insets,
                       containerSize: containerSize)
    }

    private func makeCanvasContext() -> GraphCanvasContext?
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let context = Context(device: device,
                              sampleCount: 1,
                              colorPixelFormat: .bgra8Unorm,
                              depthPixelFormat: .invalid,
                              stencilPixelFormat: .invalid)
        let canvasContext = GraphCanvasContext(rootGraph: Graph(context: context))
        canvasContext.canvasSize = contentSize
        return canvasContext
    }

    @Test func viewportSkipsBothOverlayingColumns()
    {
        let scrollGeometry = geometry(insets: EdgeInsets(top: 0, leading: 200, bottom: 0, trailing: 250.5))
        let viewport = GraphCanvasContext.scrollViewport(for: scrollGeometry)

        #expect(viewport.minX == 4130.5)
        #expect(viewport.maxX == 4994)
        #expect(viewport.minY == 4427.5)
        #expect(viewport.height == 793)

        // SwiftUI's own rects ignore the insets, so they can't stand in for this.
        #expect(scrollGeometry.bounds != viewport)
        #expect(scrollGeometry.visibleRect != viewport)
    }

    @Test func viewportIsTheWholeContainerWithNoOverlay()
    {
        let viewport = GraphCanvasContext.scrollViewport(for: geometry(insets: EdgeInsets()))

        #expect(viewport == CGRect(origin: contentOffset, size: containerSize))
    }

    @Test func aTopInsetMovesTheViewportDown()
    {
        let viewport = GraphCanvasContext.scrollViewport(for: geometry(insets: EdgeInsets(top: 52, leading: 0, bottom: 0, trailing: 0)))

        #expect(viewport.minY == contentOffset.y + 52)
        #expect(viewport.minX == contentOffset.x)
    }

    @Test func visibleGraphCenterIsTheViewportCenterInGraphCoordinates()
    {
        guard let canvasContext = makeCanvasContext() else { return }
        canvasContext.currentScrollGeometry = geometry(insets: EdgeInsets(top: 0, leading: 200, bottom: 0, trailing: 250.5))

        let viewportCenter = canvasContext.currentScrollViewport.center
        #expect(canvasContext.visibleGraphCenter == CGPoint(x: viewportCenter.x - 5000,
                                                            y: viewportCenter.y - 5000))
    }

    @Test func visibleGraphCenterFollowsTheZoom()
    {
        guard let canvasContext = makeCanvasContext() else { return }
        canvasContext.currentScrollGeometry = geometry(insets: EdgeInsets())

        // Graph point (3000, 0) is canvas (8000, 5000); show it at the viewport center at 2x.
        let viewportCenter = canvasContext.currentScrollViewport.center
        canvasContext.canvasZoomTransform = GraphCanvasZoomTransform(scale: 2)
            .placing(CGPoint(x: 8000, y: 5000), at: viewportCenter)

        let center = canvasContext.visibleGraphCenter
        #expect(abs(center.x - 3000) < 0.000001)
        #expect(abs(center.y) < 0.000001)
    }

    @Test("Dropped nodes center on the drop point without the rapid-add stagger")
    func dropCentering() throws
    {
        guard let canvasContext = makeCanvasContext() else { return }
        let graph = canvasContext.currentGraph
        let dropPosition = CGPoint(x: 300, y: -200)

        for _ in 0..<2
        {
            let node = NumberBinaryOperator(context: graph.context)
            try canvasContext.layoutNode(node)
            let offset = GraphCanvas.offset(centering: node, at: dropPosition)
            #expect(offset == CGSize(width: dropPosition.x - node.nodeSize.width / 2,
                                     height: dropPosition.y - node.nodeSize.height / 2))
        }
    }

    @available(*, deprecated)
    @Test func legacyScrollPropertiesKeepTheirRawMeaning()
    {
        guard let canvasContext = makeCanvasContext() else { return }
        canvasContext.currentScrollGeometry = geometry(insets: EdgeInsets(top: 0, leading: 200, bottom: 0, trailing: 250.5))

        #expect(canvasContext.currentScrollContentOffset == contentOffset)
        #expect(canvasContext.currentScrollContainerSize == containerSize)
        #expect(canvasContext.currentScrollOffset == canvasContext.visibleGraphCenter)

        canvasContext.currentScrollContentOffset = CGPoint(x: 100, y: 200)
        canvasContext.currentScrollContainerSize = CGSize(width: 300, height: 400)
        #expect(canvasContext.currentScrollGeometry.contentOffset == CGPoint(x: 100, y: 200))
        #expect(canvasContext.currentScrollGeometry.containerSize == CGSize(width: 300, height: 400))
    }
}
