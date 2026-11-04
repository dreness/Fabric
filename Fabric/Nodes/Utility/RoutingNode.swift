//
//  RoutingNode.swift
//  Fabric
//

import Foundation
import Satin
import SwiftUI

let routingNodeMinimumRouteCount = 2
let routingNodeMaximumRouteCount = 16

/// Shared base for the routing / switching node family (Switch, Gate, Matrix
/// Switch). Owns the route count, the value-type strategy (the Type picker), the
/// settings pane, and the route port declaration. It deliberately holds no notion of
/// *how* a route is selected — subclasses supply that: a single `Index` for
/// Switch/Gate ([[RoutingNode]]), an index map for Matrix Switch.
public class RoutingNodeBase: TypeAgnosticNode
{
    /// Mutable only through setRouteCount(_:), which clamps, guards against
    /// no-op assignments, and reconciles the ports. Init and decode assign it
    /// before Node's initializer declares the ports.
    public private(set) var routeCount: Int = routingNodeMinimumRouteCount

    private enum RoutingCodingKeys: String, CodingKey
    {
        case routeCount
    }

    public required init(context: Context)
    {
        super.init(context: context)
    }

    public init(context: Context, routeCount: Int, portType: PortType)
    {
        self.routeCount = Self.clampedRouteCount(routeCount)
        super.init(context: context, initialStrategy: portType.rawValue)
    }

    public required init(from decoder: any Decoder) throws
    {
        // Decode before super.init: the ports are declared for the saved route
        // count as Node.init(from:) makes them, so the high-index routes take
        // their saved state and the wires that name them.
        let container = try decoder.container(keyedBy: RoutingCodingKeys.self)
        routeCount = Self.clampedRouteCount(
            try container.decodeIfPresent(Int.self, forKey: .routeCount) ?? routingNodeMinimumRouteCount
        )

        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws
    {
        try super.encode(to: encoder)

        var container = encoder.container(keyedBy: RoutingCodingKeys.self)
        try container.encode(routeCount, forKey: .routeCount)
    }

    public func setRouteCount(_ count: Int)
    {
        let clamped = Self.clampedRouteCount(count)
        guard clamped != routeCount else { return }
        routeCount = clamped
        reconcileToStrategy()
    }

    public func setPortType(_ portType: PortType)
    {
        let rawValue = portType.rawValue
        guard rawValue != strategy else { return }
        strategy = rawValue
    }

    override public var settingsSize: SettingsViewSize { .Small }

    override public func settingsView() -> AnyView
    {
        AnyView(RoutingNodeSettingsView(node: self))
    }

    // MARK: - Route ports

    /// A route port, carrying the node's type.
    func routePortDeclaration(key: String, name: String, kind: PortKind, description: String) -> PortDeclaration
    {
        PortDeclaration(key: key, portType: selectedPortType, kind: kind, name: name, description: description)
    }

    static func clampedRouteCount(_ count: Int) -> Int
    {
        max(routingNodeMinimumRouteCount, min(count, routingNodeMaximumRouteCount))
    }
}

/// Single-selection routing: a scalar `Index` parameter picks one of `routeCount`
/// routes. Superclass of Switch (N inputs → 1 output) and Gate (1 input → N
/// outputs). For per-input routing to independent outputs see [[MatrixSwitchNode]].
public class RoutingNode: RoutingNodeBase
{
    public var inputIndex: ParameterPort<Int> { port(named: "inputIndex") }

    override public class func registerPorts(context: Context) -> [(name: String, port: Port)]
    {
        super.registerPorts(context: context) + [
            ("inputIndex", ParameterPort(parameter: IntParameter("Index",
                                                                 0,
                                                                 0,
                                                                 routingNodeMinimumRouteCount - 1,
                                                                 .inputfield,
                                                                 "Selected route index"))),
        ]
    }

    public override func didApplyStrategy()
    {
        super.didApplyStrategy()
        updateIndexRange()
    }

    func selectedRouteIndex() -> Int
    {
        max(0, min(inputIndex.value ?? 0, routeCount - 1))
    }

    private func updateIndexRange()
    {
        if let parameter = inputIndex.parameter as? IntParameter
        {
            parameter.max = routeCount - 1
        }

        inputIndex.onValueChanged = { [weak self] in
            self?.updateConnectionTopology()
        }

        if let value = inputIndex.value, value >= routeCount
        {
            inputIndex.value = routeCount - 1
        }

        updateConnectionTopology()
    }
}

private struct RoutingNodeSettingsView: View
{
    let node: RoutingNodeBase
    @State private var routeCount: Int

    init(node: RoutingNodeBase)
    {
        self.node = node
        self._routeCount = State(initialValue: node.routeCount)
    }

    var body: some View
    {
        VStack(alignment: .leading, spacing: 12)
        {
            Text(type(of: node).nodeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Stepper(value: Binding(
                get: { routeCount },
                set: { newRouteCount in
                    node.setRouteCount(newRouteCount)
                    routeCount = node.routeCount
                }
            ), in: routingNodeMinimumRouteCount...routingNodeMaximumRouteCount)
            {
                Text("Routes \(routeCount)")
            }

            StrategyPickerView(model: node.strategySettingsModel)
        }
        .padding()
    }
}
