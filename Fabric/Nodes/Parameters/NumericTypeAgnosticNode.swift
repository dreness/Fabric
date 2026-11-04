//
//  NumericTypeAgnosticNode.swift
//  Fabric
//

import Foundation
import Satin
import simd

public enum NumericPortStrategy: NodeStrategyOption, Equatable
{
    case virtual
    case concrete(PortType)

    public var rawValue: String
    {
        switch self
        {
        case .virtual: return "Virtual"
        case .concrete(let portType): return portType.rawValue
        }
    }

    public var portType: PortType
    {
        switch self
        {
        case .virtual: return .NumericVirtual
        case .concrete(let portType): return portType
        }
    }
}

public class NumericTypeAgnosticNode: StrategyNode
{
    public class var supportedPortTypes: [PortType] { [] }

    public override class var strategyOptions: [any NodeStrategyOption]
    {
        [NumericPortStrategy.virtual] + supportedPortTypes.map { NumericPortStrategy.concrete($0) }
    }

    public override class var separatorAfterFirstStrategy: Bool { true }

    /// The strategy's port type, resolved before each reconcile.
    public private(set) var selectedNumericPortType: PortType = .NumericVirtual

    override public func prepareDeclarations()
    {
        super.prepareDeclarations()
        self.selectedNumericPortType = Self.portType(forStrategy: strategy)
    }

    public convenience init(context: Context, portType: PortType)
    {
        self.init(context: context, initialStrategy: portType.rawValue)
    }

    /// Node-generated name: the selected numeric port type leads the title, e.g.
    /// "Float Tween" (NodeTitleView appends the type name after it). NumericVirtual
    /// — the no-configuration default — suppresses the token so the node reads as
    /// its plain type name.
    override public func deriveSubtitle() -> String? {
        let portType = selectedNumericPortType
        return portType == .NumericVirtual ? nil : portType.rawValue
    }

    public class func portType(forStrategy strategy: String) -> PortType
    {
        if strategy == NumericPortStrategy.virtual.rawValue { return .NumericVirtual }
        return supportedPortTypes.first(where: { $0.rawValue == strategy }) ?? .NumericVirtual
    }

    public func concretePortType(from port: Port?) -> PortType?
    {
        guard let port else { return nil }
        let portType = port.portType
        if portType == .NumericVirtual,
           let boxed = port.snapshotValue(),
           let boxedType = boxed.numericPortType,
           Self.supportedPortTypes.contains(boxedType)
        {
            return boxedType
        }
        if Self.supportedPortTypes.contains(portType)
        {
            return portType
        }
        if case .Array(let elementType) = portType,
           Self.supportedPortTypes.contains(portType) || Self.supportedPortTypes.contains(elementType)
        {
            return portType
        }
        return nil
    }

    /// While the node is Numeric Virtual, a wire into one of its virtual
    /// inlets from an outlet of a supported type makes that type the node's
    /// strategy, as part of the connect. An explicit choice of Virtual made
    /// while wired stands: retyping moves wires without connecting them.
    override public func inletDidConnect(_ inlet: Port, from outlet: Port)
    {
        super.inletDidConnect(inlet, from: outlet)
        guard selectedNumericPortType == .NumericVirtual,
              inlet.portType == .NumericVirtual,
              Self.supportedPortTypes.contains(outlet.portType)
        else { return }

        strategy = outlet.portType.rawValue
    }
}
