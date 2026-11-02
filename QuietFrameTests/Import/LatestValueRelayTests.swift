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
}

@MainActor
private final class AppliedValues {
    var values: [Int] = []
}
