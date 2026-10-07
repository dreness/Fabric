import SwiftUI

/// Which of the canvas's contents a framing command brings into view.
enum GraphCanvasFramingScope
{
    case selection
    case allContent
}

/// Scene-scoped actions supplied by the canvas zoom modifier; nil when unavailable.
struct GraphCanvasZoomActions
{
    let zoomIn: (() -> Void)?
    let zoomOut: (() -> Void)?
    let actualSize: (() -> Void)?
    let frame: ((GraphCanvasFramingScope) -> Void)?
    let canFrame: (GraphCanvasFramingScope) -> Bool
}

private struct GraphCanvasZoomActionsKey: FocusedValueKey
{
    typealias Value = GraphCanvasZoomActions
}

extension FocusedValues
{
    var graphCanvasZoomActions: GraphCanvasZoomActions?
    {
        get { self[GraphCanvasZoomActionsKey.self] }
        set { self[GraphCanvasZoomActionsKey.self] = newValue }
    }
}

public struct GraphCanvasZoomCommands: Commands
{
    @FocusedValue(\.graphCanvasZoomActions) private var actions

    public init() {}

    public var body: some Commands
    {
        CommandGroup(after: .toolbar)
        {
            Menu("Canvas Zoom")
            {
                Button("Zoom In") { actions?.zoomIn?() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(actions?.zoomIn == nil)

                Button("Zoom Out") { actions?.zoomOut?() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(actions?.zoomOut == nil)

                Button("Actual Size") { actions?.actualSize?() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(actions?.actualSize == nil)
            }

            Button("Frame Selected") { actions?.frame?(.selection) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!canFrame(.selection))

            // Option-Command-F is Find and Replace.
            Button("Frame All") { actions?.frame?(.allContent) }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(!canFrame(.allContent))
        }
    }

    private func canFrame(_ scope: GraphCanvasFramingScope) -> Bool
    {
        guard let actions, actions.frame != nil else { return false }
        return actions.canFrame(scope)
    }
}
