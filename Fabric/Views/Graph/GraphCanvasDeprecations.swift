import SwiftUI

extension GraphCanvasContext
{
    /// The raw scroll view content offset, measured from the container's physical
    /// leading edge rather than the unoccluded viewport.
    @available(*, deprecated, message: "Use currentScrollGeometry or currentScrollViewport")
    public var currentScrollContentOffset: CGPoint
    {
        get { currentScrollGeometry.contentOffset }
        set { currentScrollGeometry.contentOffset = newValue }
    }

    @available(*, deprecated, message: "Use currentScrollGeometry or currentScrollViewport")
    public var currentScrollContainerSize: CGSize
    {
        get { currentScrollGeometry.containerSize }
        set { currentScrollGeometry.containerSize = newValue }
    }

    @available(*, deprecated, renamed: "visibleGraphCenter")
    public var currentScrollOffset: CGPoint
    {
        visibleGraphCenter
    }
}
