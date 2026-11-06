import XCTest
import Foundation
import Satin
@testable import Fabric

/// Review evidence for the Fabric#456-458 / Satin#72-73 stack. Not part of the suite: run by
/// --filter. The reentrancy test traps (signal 5) where a removed observer is still called.
final class ReviewObserverReentrancyTests: XCTestCase
{
    /// Two ports share a parameter. The first port's change releases the second, mid-notification.
    func testReleasingAnObservingPortDuringNotification() throws
    {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["REVIEW_REENTRANCY"] == "1",
                          "Traps on the stack top; set REVIEW_REENTRANCY=1 and run it alone.")
        let parameter = FloatParameter("Shared", 0)
        let first = ParameterPort(parameter: parameter)
        var second: ParameterPort<Float>? = ParameterPort(parameter: parameter)
        weak var releasedSecond = second
        first.onValueChanged = { second = nil }

        parameter.value = 1

        XCTAssertEqual(first.value, 1)
        XCTAssertNil(releasedSecond)
        print("REVIEWSTACK tree=\(ProcessInfo.processInfo.environment["FABRIC_TREE"] ?? "unknown") reentrancy=survived")
    }
}

/// Cost of reading an observation-tracked stored property (`Port.id`) against a local copy.
final class ReviewPortIDReadBenchTests: XCTestCase
{
    private static let rounds = 9

    private static func median(_ values: [Double]) -> Double
    {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    func testObservedIDReadAgainstLocal()
    {
        let iterations = 2_000_000
        let port = NodePort<Float>(name: "Bench", kind: .Inlet)
        let other = UUID()
        var observedSamples: [Double] = []
        var localSamples: [Double] = []
        var hits = 0
        for _ in 0..<Self.rounds
        {
            var start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for _ in 0..<iterations where port.id == other { hits &+= 1 }
            observedSamples.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(iterations))

            start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let portID = port.id
            for _ in 0..<iterations where portID == other { hits &+= 1 }
            localSamples.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(iterations))
        }
        XCTAssertEqual(hits, 0)
        let tree = ProcessInfo.processInfo.environment["FABRIC_TREE"] ?? "unknown"
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2)).grouping(.never)
        print("REVIEWSTACK tree=\(tree) metric=port_id_read_ns observed=\(Self.median(observedSamples).formatted(format)) local=\(Self.median(localSamples).formatted(format))")
    }
}
