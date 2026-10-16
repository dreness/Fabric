import Testing
import Foundation
@testable import Fabric

struct GraphCanvasZoomTransformTests
{
    private let limits: ClosedRange<CGFloat> = 0.25...2

    private func expectEqual(_ actual: CGPoint, _ expected: CGPoint,
                             sourceLocation: SourceLocation = #_sourceLocation)
    {
        #expect(abs(actual.x - expected.x) < 0.000001, sourceLocation: sourceLocation)
        #expect(abs(actual.y - expected.y) < 0.000001, sourceLocation: sourceLocation)
    }

    @Test func coordinateRoundTrip()
    {
        let transform = GraphCanvasZoomTransform(scale: 0.25,
                                                translation: CGSize(width: -1234, height: 5678))
        let canvasPosition = CGPoint(x: -20000, y: 30000)
        expectEqual(transform.canvasPosition(at: transform.position(forCanvasPosition: canvasPosition)),
                    canvasPosition)
    }

    @Test func centeringPreservesZoomAtEverySupportedScale()
    {
        let viewportCenterInLayout = CGPoint(x: 7200, y: 3100)
        // A node's graph-space offset plus half the fixed canvas dimensions.
        let nodeCanvasPosition = CGPoint(x: 4200, y: 5600)

        for scale in [CGFloat(0.25), 0.75, 1, 1.5, 2]
        {
            let initial = GraphCanvasZoomTransform(scale: scale,
                                                  translation: CGSize(width: -1900, height: 700))
            let centered = initial.placing(nodeCanvasPosition, at: viewportCenterInLayout)

            #expect(centered.scale == scale)
            expectEqual(centered.position(forCanvasPosition: nodeCanvasPosition), viewportCenterInLayout)
            #expect(centered.placing(nodeCanvasPosition, at: viewportCenterInLayout) == centered)

            let nextNodePosition = CGPoint(x: 8100, y: 2900)
            let nextCentered = centered.placing(nextNodePosition, at: viewportCenterInLayout)
            #expect(nextCentered.scale == scale)
            expectEqual(nextCentered.position(forCanvasPosition: nextNodePosition), viewportCenterInLayout)
        }
    }

    @Test func successivePinchesPreserveTheirOwnAnchor()
    {
        var transform = GraphCanvasZoomTransform()
        let anchors = [CGPoint(x: 4700, y: 5200), CGPoint(x: 5500, y: 4800),
                       CGPoint(x: 1200, y: 8100)]

        for (anchor, magnification) in zip(anchors, [CGFloat(1.8), 0.3, 2.4])
        {
            let anchoredCanvasPosition = transform.canvasPosition(at: anchor)
            let unchanged = transform.magnified(by: 1, around: anchor, limits: limits)
            expectEqual(unchanged.position(forCanvasPosition: anchoredCanvasPosition), anchor)
            #expect(unchanged.scale == transform.scale)

            transform = transform.magnified(by: magnification, around: anchor, limits: limits)
            expectEqual(transform.position(forCanvasPosition: anchoredCanvasPosition), anchor)
        }
    }

    @Test func relativeMagnificationIsNotClampedIndependently()
    {
        let initial = GraphCanvasZoomTransform(scale: 0.25)
        let anchor = CGPoint(x: 6000, y: 4500)
        let result = initial.magnified(by: 3, around: anchor, limits: limits)

        #expect(result.scale == 0.75)
        expectEqual(result.position(forCanvasPosition: initial.canvasPosition(at: anchor)), anchor)
    }

    @Test func bothLimitsPreserveAnchorAndAllowReversal()
    {
        let initial = GraphCanvasZoomTransform(scale: 0.8,
                                              translation: CGSize(width: 2300, height: -700))
        let anchor = CGPoint(x: 5100, y: 3900)
        let anchoredCanvasPosition = initial.canvasPosition(at: anchor)

        for (magnification, expectedScale) in [(CGFloat(0.01), CGFloat(0.25)), (100, 2), (1.5, 1.2)]
        {
            // Each event uses the same gesture-start snapshot, including when
            // reversing back into range after overshooting a limit.
            let result = initial.magnified(by: magnification, around: anchor, limits: limits)
            #expect(abs(result.scale - expectedScale) < 0.000001)
            expectEqual(result.position(forCanvasPosition: anchoredCanvasPosition), anchor)
        }
    }

    @Test func zoomingOutAndBackAtSameAnchorRestoresTransform()
    {
        let initial = GraphCanvasZoomTransform(scale: 1.5,
                                              translation: CGSize(width: -1200, height: 800))
        let anchor = CGPoint(x: 4800, y: 5100)
        let zoomedOut = initial.magnified(by: 0.5, around: anchor, limits: limits)
        let restored = zoomedOut.magnified(by: 2, around: anchor, limits: limits)

        #expect(restored.scale == initial.scale)
        expectEqual(restored.position(forCanvasPosition: .zero),
                    initial.position(forCanvasPosition: .zero))
    }

    // MARK: - Framing

    private let scrollContentSize = CGSize(width: 10_000, height: 10_000)

    @Test func framingScalesToTheTighterAxisAndCentersTheRect() throws
    {
        // Wider than it is tall relative to the viewport, so width decides the scale.
        let viewport = CGRect(x: 4200, y: 4100, width: 1000, height: 500)
        let canvasRect = CGRect(x: 4000, y: 5000, width: 2000, height: 500)
        let framing = try #require(GraphCanvasZoomTransform.framing(canvasRect, in: viewport,
                                                                     scrollContentSize: scrollContentSize,
                                                                     limits: limits))
        let scrolledViewport = viewport.offsetBy(dx: framing.scrollDelta.width, dy: framing.scrollDelta.height)

        #expect(abs(framing.transform.scale - 0.5) < 0.000001)
        expectEqual(framing.transform.position(forCanvasPosition: canvasRect.center), scrolledViewport.center)
        expectEqual(framing.transform.position(forCanvasPosition: CGPoint(x: canvasRect.minX, y: canvasRect.midY)),
                    CGPoint(x: scrolledViewport.minX, y: scrolledViewport.midY))
    }

    @Test func framingZoomsAroundTheRectAndScrollsToIt() throws
    {
        // The case where panning by translation alone would strand most of the canvas:
        // scrolled to the top-left corner, framing a node at the canvas center.
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let canvasRect = CGRect(x: 4950, y: 4975, width: 100, height: 50)
        let framing = try #require(GraphCanvasZoomTransform.framing(canvasRect, in: viewport,
                                                                     scrollContentSize: scrollContentSize,
                                                                     limits: limits))

        #expect(framing.transform.scale == 2)
        // The rect keeps its unscaled layout position, so the canvas around it stays as
        // reachable as after a pinch on it, and the scroll brings it to the center.
        expectEqual(framing.transform.position(forCanvasPosition: canvasRect.center), canvasRect.center)
        #expect(framing.scrollDelta == CGSize(width: 4500, height: 4600))
    }

    @Test func framingTranslatesWhatScrollingCannotReach() throws
    {
        // A rect near the canvas's top-left corner can't be scrolled to the center.
        let viewport = CGRect(x: 2000, y: 3000, width: 1000, height: 800)
        let canvasRect = CGRect(x: 100, y: 50, width: 400, height: 300)
        let framing = try #require(GraphCanvasZoomTransform.framing(canvasRect, in: viewport,
                                                                     scrollContentSize: scrollContentSize,
                                                                     limits: limits))
        let scrolledViewport = viewport.offsetBy(dx: framing.scrollDelta.width, dy: framing.scrollDelta.height)

        #expect(scrolledViewport.origin == .zero)
        expectEqual(framing.transform.position(forCanvasPosition: canvasRect.center), scrolledViewport.center)
    }

    @Test func framingClampsToZoomLimitsAndStillCenters() throws
    {
        let viewport = CGRect(x: 4000, y: 4000, width: 1000, height: 1000)

        // A single small node cannot be magnified past the upper limit, and a
        // sprawling graph is not shrunk past the lower one; both stay centered.
        for (size, expectedScale) in [(CGSize(width: 10, height: 10), CGFloat(2)),
                                      (CGSize(width: 100_000, height: 100_000), 0.25)]
        {
            let canvasRect = CGRect(origin: CGPoint(x: 4500, y: 5200), size: size)
            let framing = try #require(GraphCanvasZoomTransform.framing(canvasRect, in: viewport,
                                                                         scrollContentSize: scrollContentSize,
                                                                         limits: limits))
            let scrolledViewport = viewport.offsetBy(dx: framing.scrollDelta.width, dy: framing.scrollDelta.height)

            #expect(framing.transform.scale == expectedScale)
            expectEqual(framing.transform.position(forCanvasPosition: canvasRect.center), scrolledViewport.center)
        }
    }

    @Test func framingKeepsTheRectClearOfTheViewportEdgesByTheMargin() throws
    {
        let viewport = CGRect(x: 4000, y: 4000, width: 1000, height: 500)
        let canvasRect = CGRect(x: 4000, y: 5000, width: 2000, height: 500)
        let framing = try #require(GraphCanvasZoomTransform.framing(canvasRect, in: viewport,
                                                                     scrollContentSize: scrollContentSize,
                                                                     margin: 40, limits: limits))
        let scrolledViewport = viewport.offsetBy(dx: framing.scrollDelta.width, dy: framing.scrollDelta.height)

        // Width decides: (1000 - 2 * 40) / 2000.
        #expect(abs(framing.transform.scale - 0.46) < 0.000001)
        expectEqual(framing.transform.position(forCanvasPosition: CGPoint(x: canvasRect.minX, y: canvasRect.midY)),
                    CGPoint(x: scrolledViewport.minX + 40, y: scrolledViewport.midY))
    }

    @Test func framingShrinksTheMarginInANarrowViewport() throws
    {
        // A 40pt margin would leave a 20pt-wide fit rect; a quarter of 100 leaves 50.
        let viewport = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        let canvasRect = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        let framing = try #require(GraphCanvasZoomTransform.framing(canvasRect, in: viewport,
                                                                     scrollContentSize: scrollContentSize,
                                                                     margin: 40, limits: limits))
        let scrolledViewport = viewport.offsetBy(dx: framing.scrollDelta.width, dy: framing.scrollDelta.height)

        #expect(abs(framing.transform.scale - 0.5) < 0.000001)
        expectEqual(framing.transform.position(forCanvasPosition: canvasRect.origin),
                    CGPoint(x: scrolledViewport.minX + 25, y: scrolledViewport.minY + 25))
    }

    @Test func framingAnEmptyRectOrViewportDoesNothing()
    {
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        let canvasRect = CGRect(x: 5000, y: 5000, width: 400, height: 300)

        #expect(GraphCanvasZoomTransform.framing(.zero, in: viewport,
                                                 scrollContentSize: scrollContentSize, limits: limits) == nil)
        #expect(GraphCanvasZoomTransform.framing(canvasRect, in: .zero,
                                                 scrollContentSize: scrollContentSize, limits: limits) == nil)
    }
}
