import SwiftUI

private struct CenterGraphCanvasKey: EnvironmentKey
{
    static let defaultValue: (CGPoint) -> Void = { _ in }
}

extension EnvironmentValues
{
    /// A view action accepting a graph-space position; no document state is changed.
    var centerGraphCanvas: (CGPoint) -> Void
    {
        get { self[CenterGraphCanvasKey.self] }
        set { self[CenterGraphCanvasKey.self] = newValue }
    }
}

/// Keeps pinch state in the view layer and preserves the canvas point under the pinch.
/// The committed zoom lives on the editing context, which places new nodes from it.
public struct GraphCanvasZoomModifier: ViewModifier
{
    /// Keeps framed nodes clear of the viewport edges, in layout-frame points.
    private static let framingMargin: CGFloat = 40

    private let editingContext: GraphCanvasContext
    private let canvasSize: CGSize
    @Binding private var scrollPosition: ScrollPosition
    private let allowsContentHitTesting: Bool
    private let zoomLimits: ClosedRange<CGFloat>

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState(resetTransaction: Transaction(animation: nil))
    private var gestureTransform: GraphCanvasZoomTransform?

    /// `scrollPosition` must be bound to the scroll view hosting the canvas, which
    /// must also report its geometry to `editingContext.currentScrollGeometry`.
    public init(editingContext: GraphCanvasContext,
                canvasSize: CGSize,
                scrollPosition: Binding<ScrollPosition>,
                allowsContentHitTesting: Bool = true,
                zoomLimits: ClosedRange<CGFloat> = 0.25...2)
    {
        self.editingContext = editingContext
        self.canvasSize = canvasSize
        self._scrollPosition = scrollPosition
        self.allowsContentHitTesting = allowsContentHitTesting
        self.zoomLimits = zoomLimits
    }

    private var committedTransform: GraphCanvasZoomTransform
    {
        get { editingContext.canvasZoomTransform }
        nonmutating set { editingContext.canvasZoomTransform = newValue }
    }

    public func body(content: Content) -> some View
    {
        let transform = gestureTransform ?? committedTransform
        let isIdle = gestureTransform == nil

        content
            .environment(\.centerGraphCanvas, center(on:))
            .allowsHitTesting(allowsContentHitTesting && isIdle)
            .scaleEffect(transform.scale, anchor: .topLeading)
            .offset(transform.translation)
            // This outer frame stays unscaled, so startLocation is independent
            // of the transform being edited. The gesture itself stays enabled
            // while node/connection hit testing is suspended.
            .frame(width: canvasSize.width, height: canvasSize.height)
            .background {
                GraphBackground(scale: transform.scale, translation: transform.translation)
            }
            .contentShape(.rect)
            .focusedSceneValue(\.graphCanvasZoomActions, GraphCanvasZoomActions(
                zoomIn: isIdle && committedTransform.scale < zoomLimits.upperBound
                    ? { zoom(by: 1.25) } : nil,
                zoomOut: isIdle && committedTransform.scale > zoomLimits.lowerBound
                    ? { zoom(by: 1 / 1.25) } : nil,
                actualSize: isIdle && committedTransform.scale != 1
                    ? { zoom(by: 1 / committedTransform.scale) } : nil,
                frame: isIdle ? frame : nil,
                // Evaluated by the menu, so selection changes don't invalidate the canvas.
                canFrame: editingContext.hasContent(framing:)
            ))
            .gesture(
                MagnifyGesture()
                    .updating($gestureTransform) { value, state, transaction in
                        transaction.animation = nil
                        state = committedTransform.magnified(by: value.magnification,
                                                              around: value.startLocation,
                                                              limits: zoomLimits)
                    }
                    .onEnded { value in
                        committedTransform = committedTransform.magnified(by: value.magnification,
                                                                         around: value.startLocation,
                                                                         limits: zoomLimits)
                    }
            )
    }

    private func zoom(by magnification: CGFloat)
    {
        guard gestureTransform == nil else { return }
        committedTransform = committedTransform.magnified(by: magnification,
                                                         around: editingContext.currentScrollViewport.center,
                                                         limits: zoomLimits)
    }

    private func center(on graphPosition: CGPoint)
    {
        guard gestureTransform == nil else { return }

        animatingTransformChange
        {
            committedTransform = committedTransform.placing(editingContext.canvasPosition(forGraphPosition: graphPosition),
                                                            at: editingContext.currentScrollViewport.center)
        }
    }

    /// Zooms and scrolls so the scope's contents fill the viewport, centered.
    private func frame(_ scope: GraphCanvasFramingScope)
    {
        guard gestureTransform == nil,
              let graphRect = editingContext.graphRect(framing: scope)
        else
        {
            return
        }

        let canvasRect = CGRect(origin: editingContext.canvasPosition(forGraphPosition: graphRect.origin),
                                size: graphRect.size)
        let scrollGeometry = editingContext.currentScrollGeometry

        guard let framing = GraphCanvasZoomTransform.framing(canvasRect,
                                                             in: editingContext.currentScrollViewport,
                                                             scrollContentSize: scrollGeometry.contentSize,
                                                             margin: Self.framingMargin,
                                                             limits: zoomLimits)
        else
        {
            return
        }

        animatingTransformChange
        {
            committedTransform = framing.transform
            scrollPosition.scrollTo(point: GraphCanvasContext.scrollPoint(movingViewportOf: scrollGeometry,
                                                                          by: framing.scrollDelta))
        }
    }

    private func animatingTransformChange(_ change: () -> Void)
    {
        // Repeated commands retarget the same spring instead of queuing moves.
        withAnimation(reduceMotion ? nil : .spring(duration: 0.16, bounce: 0), change)
    }
}
