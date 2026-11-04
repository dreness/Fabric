import SwiftUI

/// View-only transform from unscaled canvas coordinates to its fixed layout frame.
/// ScrollView positioning remains outside this transform.
struct GraphCanvasZoomTransform: Equatable
{
    var scale: CGFloat = 1
    var translation: CGSize = .zero

    func canvasPosition(at position: CGPoint) -> CGPoint
    {
        CGPoint(x: (position.x - translation.width) / scale,
                y: (position.y - translation.height) / scale)
    }

    func position(forCanvasPosition position: CGPoint) -> CGPoint
    {
        CGPoint(x: position.x * scale + translation.width,
                y: position.y * scale + translation.height)
    }

    /// Places an unscaled canvas point at a layout-frame point without changing zoom.
    func placing(_ canvasPosition: CGPoint, at position: CGPoint) -> Self
    {
        Self(scale: scale,
             translation: CGSize(width: position.x - canvasPosition.x * scale,
                                 height: position.y - canvasPosition.y * scale))
    }

    /// Zooms so an unscaled canvas rect fills `viewport`, a layout-frame rect inset by
    /// `margin`, and centers it there. The margin shrinks to a quarter of the viewport's
    /// shorter side rather than invert a narrow viewport. The zoom limits win: a rect too
    /// large to fit at the minimum scale stays centered and overflows, and a tiny one is
    /// not magnified past the maximum.
    ///
    /// The zoom is around the rect's center, which keeps the same canvas reachable by
    /// scrolling as a pinch on it would; `scrollDelta` then moves the viewport onto it.
    /// The scroll stops at the edges of `scrollContentSize` and the translation covers
    /// the rest. Nil for an empty rect or viewport.
    static func framing(_ canvasRect: CGRect,
                        in viewport: CGRect,
                        scrollContentSize: CGSize,
                        margin: CGFloat = 0,
                        limits: ClosedRange<CGFloat>) -> (transform: Self, scrollDelta: CGSize)?
    {
        guard canvasRect.width > 0, canvasRect.height > 0,
              viewport.width > 0, viewport.height > 0
        else
        {
            return nil
        }

        let effectiveMargin = min(margin, min(viewport.width, viewport.height) / 4)
        let fitRect = viewport.insetBy(dx: effectiveMargin, dy: effectiveMargin)

        let fittedScale = min(fitRect.width / canvasRect.width,
                              fitRect.height / canvasRect.height)
        let clampedScale = min(max(fittedScale, limits.lowerBound), limits.upperBound)

        let target = canvasRect.center

        // Zooming around the target leaves it at its unscaled layout position.
        let desiredScrollDelta = CGSize(width: target.x - fitRect.midX,
                                        height: target.y - fitRect.midY)
        let scrollDelta = CGSize(
            width: clamp(desiredScrollDelta.width,
                         from: -viewport.minX, to: scrollContentSize.width - viewport.maxX),
            height: clamp(desiredScrollDelta.height,
                          from: -viewport.minY, to: scrollContentSize.height - viewport.maxY))

        let transform = Self(scale: clampedScale).placing(target, at: fitRect.center + scrollDelta)

        return (transform, scrollDelta)
    }

    private static func clamp(_ value: CGFloat, from lowerBound: CGFloat, to upperBound: CGFloat) -> CGFloat
    {
        min(max(value, lowerBound), max(lowerBound, upperBound))
    }

    /// Magnification is relative to this snapshot, not the preceding gesture update.
    func magnified(by magnification: CGFloat,
                   around anchor: CGPoint,
                   limits: ClosedRange<CGFloat>) -> Self
    {
        let newScale = min(max(scale * magnification, limits.lowerBound), limits.upperBound)
        let anchoredPosition = canvasPosition(at: anchor)

        return Self(scale: newScale).placing(anchoredPosition, at: anchor)
    }
}
