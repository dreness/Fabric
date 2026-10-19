import SwiftUI

/// Hosts a graph canvas: scrolling, zoom, framing, and reporting scroll geometry
/// to `editingContext.currentScrollGeometry`.
public struct GraphCanvasScrollView<Content: View>: View
{
    private let editingContext: GraphCanvasContext
    private let canvasSize: CGSize
    private let initialAnchor: UnitPoint
    private let allowsContentHitTesting: Bool
    private let content: () -> Content
    @State private var scrollPosition = ScrollPosition()

    /// `initialAnchor` is the content point shown when the view first appears.
    public init(editingContext: GraphCanvasContext,
                canvasSize: CGSize,
                initialAnchor: UnitPoint = .center,
                allowsContentHitTesting: Bool = true,
                @ViewBuilder content: @escaping () -> Content)
    {
        self.editingContext = editingContext
        self.canvasSize = canvasSize
        self.initialAnchor = initialAnchor
        self.allowsContentHitTesting = allowsContentHitTesting
        self.content = content
    }

    public var body: some View
    {
        ScrollView([.horizontal, .vertical])
        {
            content()
                .frame(width: canvasSize.width, height: canvasSize.height)
                .modifier(GraphCanvasZoomModifier(editingContext: editingContext,
                                                  canvasSize: canvasSize,
                                                  scrollPosition: $scrollPosition,
                                                  allowsContentHitTesting: allowsContentHitTesting))
        }
        .defaultScrollAnchor(initialAnchor, for: .initialOffset)
        .defaultScrollAnchor(.center)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ScrollGeometry.self) { geometry in
            geometry
        } action: { _, newGeometry in
            editingContext.currentScrollGeometry = newGeometry
        }
    }
}
