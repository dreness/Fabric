import Testing
import Foundation
import Darwin
@testable import Fabric
import Satin

/// Review evidence for Fabric-Project/Fabric#388. Compiles on the PR and its base;
/// prints OSCLIFE / OSCTAKEN / OSCOFFMAIN lines. FABRIC_TREE=pr|base labels output.
@Suite("Review IO Lifecycle", .serialized)
struct ReviewIOLifecycleTests
{
    private static var tree: String { ProcessInfo.processInfo.environment["FABRIC_TREE"] ?? "unknown" }

    private static let address = "/review"

    /// An OSC message with one float argument, as OSC 1.0 lays it out.
    private static func oscPacket(address: String, value: Float) -> [UInt8]
    {
        func padded(_ string: String) -> [UInt8]
        {
            var bytes = Array(string.utf8) + [0]
            while bytes.count % 4 != 0 { bytes.append(0) }
            return bytes
        }
        let bits = value.bitPattern.bigEndian
        return padded(address) + padded(",f") + withUnsafeBytes(of: bits) { Array($0) }
    }

    private static func sendUDP(_ bytes: [UInt8], port: UInt16)
    {
        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(socketDescriptor) }
        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        destination.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socketDescriptor, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// Binds a plain UDP socket on the port, as another app holding it would.
    private static func occupy(port: UInt16) -> Int32
    {
        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0 ? socketDescriptor : -1
    }

    /// Lets main-queue hand-overs and OSCKit's delivery run.
    @MainActor
    private static func settle() async throws
    {
        try await Task.sleep(for: .milliseconds(300))
    }

    /// Sends a value and reports whether the node's outlet shows it after execute.
    @MainActor
    private static func probe(_ node: OSCReceiveNode, port: UInt16, value: Float, harness: GraphExecutionTestHarness) async throws -> Bool
    {
        sendUDP(oscPacket(address: address, value: value), port: port)
        try await settle()
        try harness.execute(node)
        let outlet = node.outputPorts().first as? NodePort<Float>
        return outlet?.value == value
    }

    @Test("OSC Receive listens from enable to disable, or only while started")
    @MainActor
    func oscListeningFollowsLifecycle() async throws
    {
        guard let harness = GraphExecutionTestHarness() else { return }
        let port: UInt16 = 47_388
        let node = OSCReceiveNode(context: harness.context, listenPort: port,
                                  addressBindings: [OSCAddressBinding(address: Self.address, dataType: .float)])
        let renderer = harness.renderer

        try node.enableExecution(renderer: renderer)
        try await Self.settle()
        let enabled = try await Self.probe(node, port: port, value: 0.25, harness: harness)

        try node.startExecution(renderer: renderer)
        try await Self.settle()
        let started = try await Self.probe(node, port: port, value: 0.5, harness: harness)

        try node.stopExecution(renderer: renderer)
        try await Self.settle()
        let stopped = try await Self.probe(node, port: port, value: 0.75, harness: harness)

        try node.disableExecution(renderer: renderer)
        try await Self.settle()

        print("OSCLIFE tree=\(Self.tree) enabled=\(enabled) started=\(started) stopped=\(stopped)")
        #expect(started)
    }

    @Test("OSC Receive on a taken port: thrown, or reported as status")
    @MainActor
    func oscTakenPort() async throws
    {
        guard let harness = GraphExecutionTestHarness() else { return }
        let port: UInt16 = 47_389
        let holder = Self.occupy(port: port)
        defer { if holder >= 0 { close(holder) } }

        let node = OSCReceiveNode(context: harness.context, listenPort: port,
                                  addressBindings: [OSCAddressBinding(address: Self.address, dataType: .float)])
        let renderer = harness.renderer

        var enableThrew = false
        var startThrew = false
        do { try node.enableExecution(renderer: renderer) } catch { enableThrew = true }
        do { try node.startExecution(renderer: renderer) } catch { startThrew = true }
        try await Self.settle()

        let statuses = node.deriveStatuses().map(\.message)
        print("OSCTAKEN tree=\(Self.tree) holderBound=\(holder >= 0) enableThrew=\(enableThrew) startThrew=\(startThrew) statuses=\(statuses)")

        try? node.stopExecution(renderer: renderer)
        try? node.disableExecution(renderer: renderer)
        try await Self.settle()
    }

    /// Crashes the process on a tree that traps off main, so it runs only when
    /// asked: FABRIC_OSC_OFFMAIN=1 swift test --filter oscProceduralInitOffMain
    @Test("OSC Receive's public initializer off the main thread")
    func oscProceduralInitOffMain() async throws
    {
        guard ProcessInfo.processInfo.environment["FABRIC_OSC_OFFMAIN"] == "1" else { return }
        guard let harness = GraphExecutionTestHarness() else { return }

        print("OSCOFFMAIN tree=\(Self.tree) isMainThread=\(pthread_main_np() != 0) constructing")
        fflush(stdout)
        let node = OSCReceiveNode(context: harness.context, listenPort: 47_390,
                                  addressBindings: [OSCAddressBinding(address: Self.address, dataType: .float)])
        print("OSCOFFMAIN tree=\(Self.tree) constructed outlets=\(node.outputPorts().count)")
    }
}
