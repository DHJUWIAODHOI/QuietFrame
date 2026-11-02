import XCTest
@testable import QuietFrame

@MainActor
final class LatestValueRelayTests: XCTestCase {
    func testTheLastValueIsAppliedAndValuesNeverGoBackwards() async {
        let applied = AppliedValues()
        let relay = LatestValueRelay<Int> { applied.values.append($0) }

        await Task.detached {
            for value in 1...1_000 {
                relay.send(value)
            }
        }.value
        await relay.finish()

        XCTAssertEqual(applied.values.last, 1_000)
        XCTAssertEqual(applied.values, applied.values.sorted())
        XCTAssertEqual(Set(applied.values).count, applied.values.count)
    }

    func testFinishingWithoutValuesAppliesNothing() async {
        let applied = AppliedValues()
        let relay = LatestValueRelay<Int> { applied.values.append($0) }

        await relay.finish()

        XCTAssertEqual(applied.values, [])
    }

    /// Without `finish()`, the relay's task ends once the relay is released, letting go of what it applies to.
    func testReleasingARelayWithoutFinishingEndsItsTask() async throws {
        var applied: AppliedValues? = AppliedValues()
        weak var releasedApplied = applied
        var relay: LatestValueRelay<Int>? = LatestValueRelay<Int> { [applied] value in
            applied?.values.append(value)
        }
        relay?.send(7)
        applied = nil

        relay = nil
        for _ in 0..<1_000 where releasedApplied != nil {
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertNil(releasedApplied, "The relay's task kept running after the relay was released")
    }
}

@MainActor
private final class AppliedValues {
    var values: [Int] = []
}
