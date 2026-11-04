//
//  StrategyNode.swift
//  Fabric
//
//  Shared base for nodes that build their port set from a user-chosen
//  strategy (e.g. "Euler" vs "Axis Angle" vs "Target") rather than a fixed
//  shape. The strategy lives in the Settings view, not on a port: anything
//  that reshapes a node's ports must only be reachable via explicit user
//  interaction in the inspector, never via graph wiring/automation, since a
//  runtime-driven strategy switch would churn ports and silently disconnect
//  wires on every change. This is the same lifecycle MathExpressionNode
//  already uses for its (also non-port) stringExpression property.
//

import Foundation
import Satin
import Metal
import SwiftUI

// MARK: - NodeStrategyOption

/// Any enum or type whose rawValue String identifies a StrategyNode strategy.
/// Conforming types serve as compile-time-checked strategy parameters for
/// programmatic node construction, replacing raw String literals.
public protocol NodeStrategyOption {
    var rawValue: String { get }
}

// MARK: - Shared family enums

/// Transform composition/decomposition mode: Translation-Rotation-Scale or
/// raw column vectors.  Shared by ComposeTransformNode, DecomposeTransformNode,
/// ComposeTransformArrayNode, and DecomposeTransformArrayNode.
public enum TransformCompositionMode: String, NodeStrategyOption, CaseIterable {
    case trs     = "TRS"
    case columns = "Columns"
}

/// Orientation composition mode: Euler angles, Axis + Angle, or aim-at-Target.
/// Shared by ComposeOrientationNode and ComposeOrientationArrayNode.
public enum OrientationCompositionMode: String, NodeStrategyOption, CaseIterable {
    case euler     = "Euler"
    case axisAngle = "Axis Angle"
    case target    = "Target"
}

/// Orientation decomposition mode.
/// Shared by DecomposeOrientationNode and DecomposeOrientationArrayNode.
public enum OrientationDecompositionMode: String, NodeStrategyOption, CaseIterable {
    case toEuler     = "To Euler"
    case toAxisAngle = "To Axis Angle"
}

/// Geometry-to-transform extraction mode.
/// Used by GeometryToTransformArrayNode.
public enum GeometryToTransformMode: String, NodeStrategyOption, CaseIterable {
    case transform  = "Transform"
    case components = "Components"
}

/// Vector type for consolidated Compose/Decompose vector nodes (single and array).
/// Raw values delegate to PortType so serialised strategy strings never drift.
public enum VectorType: NodeStrategyOption, CaseIterable {
    case float2, float3, float4

    public var rawValue: String {
        switch self {
        case .float2: return PortType.Vector2.rawValue
        case .float3: return PortType.Vector3.rawValue
        case .float4: return PortType.Vector4.rawValue
        }
    }

    /// Convenience back-conversion for execute dispatch.
    public var portType: PortType {
        switch self {
        case .float2: return .Vector2
        case .float3: return .Vector3
        case .float4: return .Vector4
        }
    }

    /// Component labels and count for this vector type.
    public var componentLabels: [String] {
        switch self {
        case .float2: return ["X", "Y"]
        case .float3: return ["X", "Y", "Z"]
        case .float4: return ["X", "Y", "Z", "W"]
        }
    }
}

// MARK: - StrategyNode

/// Open so plugins can define strategy nodes: subclass, override `strategyOptions`, and
/// declare the ports for `strategy` in `declaredPorts()`.
open class StrategyNode: Node
{
    /// Ordered strategy options — the single source of truth for the picker and
    /// for programmatic construction.  Subclasses override this; never override
    /// `strategies` directly.
    open class var strategyOptions: [any NodeStrategyOption] { [] }

    /// Derived from strategyOptions — do not override.
    public class var strategies: [String] { strategyOptions.map(\.rawValue) }
    open class var defaultStrategy: String { strategies.first ?? "" }

    /// When true, the picker inserts a visual separator after the first strategy in the list.
    open class var separatorAfterFirstStrategy: Bool { false }

    /// Standard behaviour: the node-generated `subtitle` is the active strategy,
    /// e.g. "vec3" for "Vector Compose", or "Random" for "Number Generator".
    /// `NodeTitleView` renders the type name after it (yielding "vec3 Vector
    /// Compose"), so the strategy must not repeat it. An unrecognised strategy
    /// (e.g. a legacy or renamed case) falls back to the plain type name.
    ///
    /// Subclasses wanting a different title override `deriveSubtitle()` directly:
    /// return nil for the plain type-name title, or a bespoke string — as the
    /// type-agnostic nodes do, suppressing the token for their Virtual default.
    override open func deriveSubtitle() -> String?
    {
        Self.strategies.contains(strategy) ? strategy : nil
    }

    /// A strategy string resolved to its typed option, or nil when it matches
    /// none (e.g. a removed or renamed case).
    public class func strategyOption<T: NodeStrategyOption>(matching rawValue: String, as _: T.Type = T.self) -> T?
    {
        strategyOptions.first { $0.rawValue == rawValue } as? T
    }

    /// The currently selected strategy resolved to its typed option.
    public func strategyOption<T: NodeStrategyOption>(as _: T.Type = T.self) -> T?
    {
        // `strategyOptions` builds its array on every call; resolve once per strategy.
        if resolvedStrategyRawValue != strategy
        {
            resolvedStrategyRawValue = strategy
            resolvedStrategyOption = Self.strategyOptions.first { $0.rawValue == strategy }
        }
        return resolvedStrategyOption as? T
    }

    private var resolvedStrategyRawValue: String?
    private var resolvedStrategyOption: (any NodeStrategyOption)?

    var strategy: String
    {
        didSet
        {
            guard oldValue != strategy else { return }
            let previousStrategy = oldValue

            if let graph
            {
                graph.withoutUndoRegistration {
                    self.reconcileToStrategy()
                }
                graph.undoManager?.registerUndo(withTarget: self) { node in
                    node.strategy = previousStrategy
                }
                graph.undoManager?.setActionName("Change Node Strategy")
            }
            else
            {
                self.reconcileToStrategy()
            }

            // `subtitle` is derived from `strategy`; notify so the title refreshes.
            self.subtitleSubject.send()
        }
    }

    private enum StrategyCodingKeys: String, CodingKey
    {
        case strategy
    }

    public required init(from decoder: any Decoder) throws
    {
        let container = try decoder.container(keyedBy: StrategyCodingKeys.self)
        let decoded = try container.decodeIfPresent(String.self, forKey: .strategy)

        // Initializing assignment, before super.init: didSet does not fire,
        // and Node's initializer declares the ports for the saved strategy.
        self.strategy = decoded ?? Self.defaultStrategy

        try super.init(from: decoder)
        self.didApplyStrategy()
    }

    open override func encode(to encoder: Encoder) throws
    {
        try super.encode(to: encoder)

        var container = encoder.container(keyedBy: StrategyCodingKeys.self)
        try container.encode(self.strategy, forKey: .strategy)
    }

    public required init(context: Context)
    {
        self.strategy = Self.defaultStrategy
        super.init(context: context)
        self.didApplyStrategy()
    }

    /// Designated init for programmatic construction with a specific initial strategy.
    /// Sets strategy before super.init so didSet never fires and Node's
    /// initializer declares the ports for it.
    public init(context: Context, initialStrategy: String)
    {
        self.strategy = initialStrategy
        super.init(context: context)
        self.didApplyStrategy()
    }

    /// Convenience init for compile-time-checked programmatic construction.
    public convenience init(context: Context, strategy: some NodeStrategyOption)
    {
        self.init(context: context, initialStrategy: strategy.rawValue)
    }

    override open func providesSettingsView() -> Bool { true }

    override open var settingsSize: SettingsViewSize { .Mini }

    override open func settingsView() -> AnyView
    {
        AnyView(StrategyPickerView(model: strategySettingsModel))
    }

    /// Shared settings model behind the strategy picker; composite settings
    /// views (e.g. the routing nodes') reuse it to embed StrategyPickerView.
    public var strategySettingsModel: SettingsModel { _settingsModel }

    /// Brings the ports to the declarations for the current strategy, then
    /// lets a subclass reset the state that follows it.
    func reconcileToStrategy()
    {
        self.reconcilePorts()
        self.didApplyStrategy()
    }

    /// Runs once the ports stand for the strategy: after init, decode and every
    /// strategy change. For a subclass's runtime state that follows the
    /// strategy, as a held value resets when the type it holds changes. Ports
    /// come from declaredPorts(), which a subclass computes from `strategy`.
    open func didApplyStrategy() { }

    // MARK: - Settings Model

    @Observable public final class SettingsModel
    {
        let strategies: [String]
        let separatorAfterFirst: Bool
        var strategy: String
        {
            didSet
            {
                guard strategy != node?.strategy else { return }
                node?.strategy = strategy
            }
        }
        private weak var node: StrategyNode?

        init(node: StrategyNode)
        {
            self.node = node
            self.strategies = type(of: node).strategies
            self.separatorAfterFirst = type(of: node).separatorAfterFirstStrategy
            self.strategy = node.strategy
        }
    }

    private lazy var _settingsModel = SettingsModel(node: self)
}

public struct StrategyPickerView: View
{
    @Bindable var model: StrategyNode.SettingsModel

    public init(model: StrategyNode.SettingsModel)
    {
        self.model = model
    }

    public var body: some View
    {
        Picker("Type", selection: $model.strategy)
        {
            if model.separatorAfterFirst, let first = model.strategies.first
            {
                Text(first).tag(first)
                Divider()
                ForEach(model.strategies.dropFirst(), id: \.self) { Text($0).tag($0) }
            }
            else
            {
                ForEach(model.strategies, id: \.self) { Text($0).tag($0) }
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
    }
}

/// A strategy picker followed by usage guidance for the currently-selected
/// strategy. Reusable by any StrategyNode whose modes benefit from an
/// explanatory blurb; `guidance` maps a strategy raw value to its description.
public struct StrategyGuidanceView: View
{
    @Bindable var model: StrategyNode.SettingsModel
    let guidance: (String) -> String

    public init(model: StrategyNode.SettingsModel, guidance: @escaping (String) -> String)
    {
        self.model = model
        self.guidance = guidance
    }

    public var body: some View
    {
        VStack(alignment: .leading)
        {
            StrategyPickerView(model: model)

            Text(guidance(model.strategy))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
