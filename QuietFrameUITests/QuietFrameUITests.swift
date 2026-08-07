import XCTest

final class QuietFrameUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchStartsBehindAuthenticationGate() {
        let app = XCUIApplication()
        app.launch()

        let onboarding = app.otherElements["onboarding"]
        let unlock = app.otherElements["unlock-screen"]
        let recovery = app.otherElements["key-recovery-required"]
        let protectedEntry = NSPredicate { _, _ in
            onboarding.exists || unlock.exists || recovery.exists
        }
        let expectation = XCTNSPredicateExpectation(predicate: protectedEntry, object: nil)

        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
        XCTAssertFalse(app.otherElements["main-tabs"].exists)
    }
}
