import XCTest

final class QuietFrameUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchStartsBehindAuthenticationGate() {
        let app = XCUIApplication()
        app.launch()

        // SwiftUI may attach a container's identifier to its children, so match any element type.
        let elements = app.descendants(matching: .any)
        let gateScreens = ["onboarding", "unlock-screen", "key-recovery-required"]
        let protectedEntry = NSPredicate { _, _ in
            gateScreens.contains { elements[$0].firstMatch.exists }
        }
        let expectation = XCTNSPredicateExpectation(predicate: protectedEntry, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 20)

        let otherScreens = ["vault-retry-required", "migration-error", "main-tabs", "privacy-shield", "launch"]
            .filter { elements[$0].firstMatch.exists }
        XCTAssertEqual(
            result,
            .completed,
            "No authentication gate appeared. App state: \(app.state.rawValue). Other visible screens: \(otherScreens)"
        )
        XCTAssertFalse(elements["main-tabs"].firstMatch.exists)
    }
}
