//
//  GraphCanvasContext.swift
//  Fabric
//
//  Created by Claude on 3/26/26.
//

import SwiftUI

struct GraphConnectionPair: Identifiable
{
    struct ID: Hashable
    {
        let outletID: UUID
        let inletID: UUID
    }

    let outlet: Port
    let inlet: Port
    let connection: Connection

    var id: ID
    {
        ID(outletID: outlet.id, inletID: inlet.id)
    }
}

/// Owns all editor session state for a node canvas: subgraph navigation,
/// scroll position, drag preview, port hit-testing, selection tracking,
/// and auto-layout timing for rapid node adds.
///
/// Views should depend on this single object rather than reaching into
/// `Graph` for UI concerns. `Graph` remains a pure document model.
@Observable
public class GraphCanvasContext
{
    // MARK: - Navigation

    public let rootGraph: Graph
    public private(set) var entries: [SubgraphNode] = []

    /// The graph currently being displayed and edited.
    public var currentGraph: Graph
    {
        entries.last?.subGraph ?? rootGraph
    }
    
    // MARK: - Canvas Interaction State

    /// The canvas scroll view's latest geometry; stored so scrolling doesn't invalidate views.
    @ObservationIgnored public var currentScrollGeometry = ScrollGeometry(contentOffset: .zero,
                                                                          contentSize: .zero,
                                                                          contentInsets: EdgeInsets(),
                                                                          containerSize: .zero)

    /// The unoccluded visible region of the canvas in scroll-content coordinates.
    public var currentScrollViewport: CGRect
    {
        Self.scrollViewport(for: currentScrollGeometry)
    }

    /// The canvas zoom, owned here so node placement can see what is on screen.
    var canvasZoomTransform = GraphCanvasZoomTransform()

    /// The graph position at the center of the unoccluded viewport, accounting for zoom.
    /// Newly added nodes and notes are placed here.
    public var visibleGraphCenter: CGPoint
    {
        let canvasCenter = canvasZoomTransform.canvasPosition(at: currentScrollViewport.center)
        return graphPosition(forCanvasPosition: canvasCenter)
    }

    /// Fixed graph canvas size; used to translate model-space node positions into canvas coordinates.
    @ObservationIgnored public var canvasSize: CGSize = .zero

    /// Port currently being dragged (for preview line rendering).
    var dragPreviewSourcePortID: UUID? = nil

    /// Current endpoint of the drag preview line.
    var dragPreviewTargetPosition: CGPoint? = nil

    @ObservationIgnored private let titleHeight: CGFloat = 30
    @ObservationIgnored private let portVStackSpacing: CGFloat = 10
    @ObservationIgnored private let portRowHeight: CGFloat = 15
    @ObservationIgnored private let outletTopSpacerHeight: CGFloat = 25
    @ObservationIgnored private var cachedConnectionGraphID: UUID?
    @ObservationIgnored private var cachedConnectionRevision: Int = 0
    @ObservationIgnored private var cachedConnectionNodeCount: Int = 0
    @ObservationIgnored private var cachedConnectionPairs: [GraphConnectionPair] = []

    func connectionPairs(for graph: Graph) -> [GraphConnectionPair]
    {
        if cachedConnectionGraphID == graph.id,
           cachedConnectionRevision == graph.connectionRevision,
           cachedConnectionNodeCount == graph.nodes.count
        {
            return cachedConnectionPairs
        }

        cachedConnectionPairs = graph.connections.compactMap { connection in
            guard let outlet = graph.nodePort(forID: connection.outletPortID),
                  let inlet = graph.nodePort(forID: connection.inletPortID)
            else { return nil }

            return GraphConnectionPair(outlet: outlet, inlet: inlet, connection: connection)
        }
        cachedConnectionGraphID = graph.id
        cachedConnectionRevision = graph.connectionRevision
        cachedConnectionNodeCount = graph.nodes.count

        return cachedConnectionPairs
    }

    public func graphPosition(for port: Port) -> CGPoint?
    {
        guard let node = port.node else { return nil }

        return self.graphPosition(for: port, nodeOffset: node.offset, nodeSize: node.nodeSize)
    }

    public func graphPosition(for port: Port, nodeOffset: CGSize, nodeSize: CGSize) -> CGPoint?
    {
        guard let node = port.node else { return nil }

        let xOffset: CGFloat
        let yFromTop: CGFloat
        let sameKindPorts = node.ports.filter { $0.kind == port.kind }
        let portIndex = sameKindPorts.firstIndex(where: { $0.id == port.id }) ?? 0

        switch port.kind
        {
        case .Inlet:
            xOffset = -nodeSize.width / 2
            yFromTop = outletTopSpacerHeight + portVStackSpacing + CGFloat(portIndex) * (portRowHeight + portVStackSpacing) +  portRowHeight / 2

        case .Outlet:
            xOffset = nodeSize.width / 2
            yFromTop = outletTopSpacerHeight + portVStackSpacing + CGFloat(portIndex) * (portRowHeight + portVStackSpacing) + portRowHeight / 2
        }

        return CGPoint(x: nodeOffset.width + xOffset,
                       y: nodeOffset.height + yFromTop - nodeSize.height / 2)
    }

    public func canvasPosition(for port: Port) -> CGPoint?
    {
        guard let graphPosition = self.graphPosition(for: port) else { return nil }

        return self.canvasPosition(forGraphPosition: graphPosition)
    }

    public func canvasPosition(for port: Port, nodeOffset: CGSize, nodeSize: CGSize) -> CGPoint?
    {
        guard let graphPosition = self.graphPosition(for: port, nodeOffset: nodeOffset, nodeSize: nodeSize) else { return nil }

        return self.canvasPosition(forGraphPosition: graphPosition)
    }

    /// Graph coordinates are centered on the canvas; canvas coordinates start at its corner.
    public func canvasPosition(forGraphPosition graphPosition: CGPoint) -> CGPoint
    {
        graphPosition + canvasSize / 2
    }

    public func graphPosition(forCanvasPosition canvasPosition: CGPoint) -> CGPoint
    {
        canvasPosition - canvasSize / 2
    }

    public func nearestPortID(to graphPosition: CGPoint, maximumDistance: CGFloat = 25) -> UUID?
    {
        var closestPort: (id: UUID, distance: CGFloat)? = nil

        for node in currentGraph.nodes
        {
            for port in node.ports
            {
                guard let portPosition = self.canvasPosition(for: port) else { continue }

                let distance = hypot(graphPosition.x - portPosition.x, graphPosition.y - portPosition.y)
                guard distance < maximumDistance else { continue }

                if let currentClosest = closestPort
                {
                    if distance < currentClosest.distance
                    {
                        closestPort = (id: port.id, distance: distance)
                    }
                }
                else
                {
                    closestPort = (id: port.id, distance: distance)
                }
            }
        }

        return closestPort?.id
    }

    // MARK: - Scroll Viewport

    /// The unoccluded part of the canvas, in scroll-content coordinates.
    ///
    /// Sidebar and inspector overlay the scroll view. `containerSize` excludes them,
    /// but `contentOffset` is measured from the container's physical leading edge,
    /// behind the sidebar, so the origin is shifted by the insets. `geometry.bounds`
    /// and `visibleRect` are both `(contentOffset, containerSize)` and miss that shift.
    public static func scrollViewport(for geometry: ScrollGeometry) -> CGRect
    {
        CGRect(x: geometry.contentOffset.x + geometry.contentInsets.leading,
               y: geometry.contentOffset.y + geometry.contentInsets.top,
               width: geometry.containerSize.width,
               height: geometry.containerSize.height)
    }

    /// The point to pass to `ScrollPosition.scrollTo(point:)` to move the viewport by `delta`.
    /// `scrollTo(point:)` places the point at the inset-adjusted leading edge, not at
    /// the raw `contentOffset`.
    static func scrollPoint(movingViewportOf geometry: ScrollGeometry, by delta: CGSize) -> CGPoint
    {
        scrollViewport(for: geometry).origin + delta
    }

    // MARK: - Framing

    /// Whether `graphRect(framing:)` would find anything. Reads selection and membership
    /// only, not positions, so observers aren't invalidated by node drags.
    func hasContent(framing scope: GraphCanvasFramingScope) -> Bool
    {
        let graph = currentGraph

        switch scope
        {
        case .selection:
            return graph.nodes.contains { graph.viewModel(for: $0).isSelected }

        case .allContent:
            return !(graph.nodes.isEmpty && graph.notes.isEmpty)
        }
    }

    /// The rect in graph coordinates enclosing the scope's nodes and notes in the
    /// graph being displayed, or nil when the scope is empty.
    func graphRect(framing scope: GraphCanvasFramingScope) -> CGRect?
    {
        let graph = currentGraph

        let enclosedRects: [CGRect]
        switch scope
        {
        case .selection:
            enclosedRects = graph.selectedNodes.map { graph.viewModel(for: $0).graphRect }

        case .allContent:
            // A note's rect is already in graph coordinates.
            enclosedRects = graph.nodes.map { graph.viewModel(for: $0).graphRect }
                + graph.notes.map(\.rect)
        }

        return enclosedRects.reduce(nil) { enclosingRect, rect in
            enclosingRect?.union(rect) ?? rect
        }
    }

    // MARK: - Auto-Layout Timing

    @ObservationIgnored private let nodeOffset = CGSize(width: 20, height: 20)
    @ObservationIgnored private var currentNodeOffset = CGSize.zero
    @ObservationIgnored private var lastAddedTime: TimeInterval = .zero
    @ObservationIgnored private var nodeAddedResetTime: TimeInterval = 10.0

    // MARK: - Init

    public init(rootGraph: Graph)
    {
        self.rootGraph = rootGraph
    }
    
    public func enter(_ node: SubgraphNode)
    {
        entries.append(node)
        syncUndoManager()
    }

    public func pop()
    {
        guard !entries.isEmpty else { return }
        entries.removeLast()
        syncUndoManager()
    }

    public func popTo(_ node: SubgraphNode)
    {
        guard let index = entries.firstIndex(where: { $0.id == node.id }) else { return }
        entries = Array(entries.prefix(through: index))
        syncUndoManager()
    }

    public func popToRoot()
    {
        entries.removeAll()
        syncUndoManager()
    }

    // MARK: - Interactive Node Addition

    /// Add a node from a registry wrapper via user interaction.
    /// Positions the node at the visible graph center and staggers
    /// rapid successive adds so they don't pile on top of each other.
    public func layoutNode(_ node: Node) throws
    {
        let graph = currentGraph
        node.offset = self.calcInteractiveOffset(for: node)
    }

    /// Calculates the offset for a user-initiated add: centered on the
    /// visible graph center, plus a stagger when nodes are added in
    /// quick succession.
    private func calcInteractiveOffset(for node: Node) -> CGSize
    {
        let center = visibleGraphCenter
        let base = CGSize(width: center.x - node.nodeSize.width / 2.0,
                          height: center.y - node.nodeSize.height / 4.0)
        return base + calcRapidAddStagger()
    }

    /// Returns an accumulated offset when nodes are added within
    /// `nodeAddedResetTime` of each other, so rapid adds fan out
    /// rather than stacking.
    private func calcRapidAddStagger() -> CGSize
    {
        let deltaTime = Date.now.timeIntervalSinceReferenceDate - lastAddedTime
        lastAddedTime = Date.now.timeIntervalSinceReferenceDate

        if deltaTime < nodeAddedResetTime
        {
            currentNodeOffset += nodeOffset
        }
        else
        {
            currentNodeOffset = .zero
        }

        return currentNodeOffset
    }

    // MARK: - Private

    /// Propagate the undo manager to the active subgraph so undo works at any nesting level.
    private func syncUndoManager()
    {
        if let active = entries.last?.subGraph, let undoManager = rootGraph.undoManager
        {
            active.undoManager = undoManager
        }
    }
}
