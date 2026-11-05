import XCTest
import Foundation
import Metal
import Satin
import Fabric

/// Review evidence for Fabric#455: named lookups by registry size, and port assignment cost.
/// Prints PORTBENCH lines. Release only: `swift test -c release -Xswiftc -enable-testing --filter ReviewPortLookupBenchTests`.
final class ReviewPortLookupBenchTests: XCTestCase
{
    private static let tree = ProcessInfo.processInfo.environment["FABRIC_TREE"] ?? "unknown"
    private static let rounds = 9

    private func makeContext() throws -> Context
    {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm)
    }

    private static func median(_ values: [Double]) -> Double
    {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func nanosecondsPerOperation(operations: Int, _ body: () -> Void) -> Double
    {
        var samples: [Double] = []
        for _ in 0..<rounds
        {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            body()
            let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
            samples.append(Double(elapsed) / Double(operations))
        }
        return median(samples)
    }

    /// Lookups of the first, middle and last registered names plus a miss, at several registry sizes.
    func testNamedLookupBySize() throws
    {
        let context = try makeContext()
        let iterations = 200_000
        for totalPorts in [4, 8, 12, 16, 17, 20, 24, 32]
        {
            let node = NumberBinaryOperator(context: context)
            let builtIn = node.ports.count
            for index in 0..<max(0, totalPorts - builtIn)
            {
                node.addDynamicPort(NodePort<Float>(name: "Extra \(index)", kind: .Inlet), name: "extraInputNumber\(index)")
            }
            XCTAssertEqual(node.ports.count, max(totalPorts, builtIn))
            let lastName = totalPorts > builtIn ? "extraInputNumber\(totalPorts - builtIn - 1)" : "outputNumber"
            let names = ["inputNumber1", "inputParam", lastName, "missingPortName"]
            var hits = 0
            let nanoseconds = Self.nanosecondsPerOperation(operations: iterations * names.count)
            {
                for _ in 0..<iterations
                {
                    for name in names where node.findPort(named: name, as: Port.self) != nil { hits &+= 1 }
                }
            }
            XCTAssertEqual(hits, Self.rounds * iterations * 3)
            print("PORTBENCH tree=\(Self.tree) metric=lookup_ns ports=\(node.ports.count) median=\(nanoseconds.formatted(.number.precision(.fractionLength(2)).grouping(.never)))")
        }
    }

    /// One name at a time: the last registered (a scan's best case), the first registered and a miss (its worst).
    func testNamedLookupByPosition() throws
    {
        let context = try makeContext()
        let iterations = 500_000
        for totalPorts in [4, 8, 12, 16, 17, 24]
        {
            let node = NumberBinaryOperator(context: context)
            let builtIn = node.ports.count
            for index in 0..<max(0, totalPorts - builtIn)
            {
                node.addDynamicPort(NodePort<Float>(name: "Extra \(index)", kind: .Inlet), name: "extraInputNumber\(index)")
            }
            let lastName = totalPorts > builtIn ? "extraInputNumber\(totalPorts - builtIn - 1)" : "outputNumber"
            for (position, name) in [("last", lastName), ("first", "inputNumber1"), ("miss", "missingPortName")]
            {
                var hits = 0
                let nanoseconds = Self.nanosecondsPerOperation(operations: iterations)
                {
                    for _ in 0..<iterations where node.findPort(named: name, as: Port.self) != nil { hits &+= 1 }
                }
                XCTAssertEqual(hits, position == "miss" ? 0 : Self.rounds * iterations)
                print("PORTBENCH tree=\(Self.tree) metric=lookup_position_ns ports=\(node.ports.count) position=\(position) median=\(nanoseconds.formatted(.number.precision(.fractionLength(2)).grouping(.never)))")
            }
        }
    }

    /// A model of `PortRegistry.port(named:)`'s scan over `names`, run backwards (as the PR does) and
    /// forwards. Shadowed keys are nil, so each live key appears once and both directions agree.
    /// Tree-independent: it measures the loop, not either tree's registry.
    func testScanDirectionModel() throws
    {
        let iterations = 500_000
        let builtIns = ["inputNumber1", "inputNumber2", "inputParam", "outputNumber"]
        for totalPorts in [4, 8, 12, 16]
        {
            let names = ContiguousArray<String?>(builtIns + (0..<(totalPorts - builtIns.count)).map { "extraInputNumber\($0)" })
            for (position, target) in [("first", "inputNumber1"), ("last", names[names.count - 1] ?? ""), ("miss", "missingPortName")]
            {
                for direction in ["backward", "forward"]
                {
                    var found = 0
                    let nanoseconds = Self.nanosecondsPerOperation(operations: iterations)
                    {
                        for _ in 0..<iterations
                        {
                            var match: Int? = nil
                            if direction == "backward"
                            {
                                var index = names.endIndex
                                while index > names.startIndex
                                {
                                    index -= 1
                                    if names[index] == target { match = index; break }
                                }
                            }
                            else
                            {
                                for index in names.indices where names[index] == target { match = index; break }
                            }
                            if match != nil { found &+= 1 }
                        }
                    }
                    XCTAssertEqual(found, position == "miss" ? 0 : Self.rounds * iterations)
                    print("PORTBENCH tree=model metric=scan_ns ports=\(totalPorts) position=\(position) direction=\(direction) median=\(nanoseconds.formatted(.number.precision(.fractionLength(2)).grouping(.never)))")
                }
            }
        }
    }

    /// Assigning a value to ports without a publishing proxy: valueDidSet runs on each.
    func testValueAssignmentWithoutProxy() throws
    {
        let iterations = 2_000_000
        let port = NodePort<Float>(name: "Bench", kind: .Inlet)
        var value: Float = 0
        let nanoseconds = Self.nanosecondsPerOperation(operations: iterations)
        {
            for _ in 0..<iterations
            {
                value += 1
                port.value = value
            }
        }
        XCTAssertEqual(port.value, value)
        print("PORTBENCH tree=\(Self.tree) metric=assign_ns kind=NodePort<Float> median=\(nanoseconds.formatted(.number.precision(.fractionLength(2)).grouping(.never)))")

        let parameterPort = ParameterPort(parameter: FloatParameter("Bench", 0))
        let parameterNanoseconds = Self.nanosecondsPerOperation(operations: iterations)
        {
            for _ in 0..<iterations
            {
                value += 1
                parameterPort.value = value
            }
        }
        XCTAssertEqual(parameterPort.value, value)
        print("PORTBENCH tree=\(Self.tree) metric=assign_ns kind=ParameterPort<Float> median=\(parameterNanoseconds.formatted(.number.precision(.fractionLength(2)).grouping(.never)))")
    }
}
