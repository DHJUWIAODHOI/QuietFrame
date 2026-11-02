import XCTest
@testable import QuietFrame

@MainActor
final class BlockingWorkTests: XCTestCase {
    /// More jobs than cores block at once. They all start, and another Swift task still runs while they wait; neither
    /// happens if the work holds Swift's cooperative threads.
    func testBlockedWorkLeavesSwiftConcurrencyFree() {
        let queue = DispatchQueue(label: "com.quietframe.vault.tests.blocking-work", attributes: .concurrent)
        let jobCount = ProcessInfo.processInfo.activeProcessorCount + 2
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer {
            for _ in 0..<jobCount {
                release.signal()
            }
        }
        for _ in 0..<jobCount {
            Task.detached {
                try await BlockingWork.run(on: queue) { () -> Void in
                    started.signal()
                    release.wait()
                }
            }
        }

        var startedCount = 0
        let deadline = DispatchTime.now() + 10
        while startedCount < jobCount, started.wait(timeout: deadline) == .success {
            startedCount += 1
        }
        XCTAssertEqual(startedCount, jobCount, "Every blocking job starts, however many cores there are")

        let probe = expectation(description: "A Swift task ran while the jobs were blocked")
        Task.detached {
            probe.fulfill()
        }
        wait(for: [probe], timeout: 5)
    }

    func testWorkThatHasNotStartedIsSkippedWhenCancelled() {
        let queue = DispatchQueue(label: "com.quietframe.vault.tests.blocking-work-serial")
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.async {
            holding.signal()
            release.wait()
        }
        XCTAssertEqual(holding.wait(timeout: .now() + 10), .success)
        let cancelled = expectation(description: "The cancelled job threw CancellationError")
        let workRan = expectation(description: "The cancelled job's work ran")
        workRan.isInverted = true

        let job = Task.detached {
            do {
                try await BlockingWork.run(on: queue) { () -> Void in
                    workRan.fulfill()
                }
            } catch is CancellationError {
                cancelled.fulfill()
            } catch {}
        }
        job.cancel()
        release.signal()

        wait(for: [cancelled], timeout: 10)
        wait(for: [workRan], timeout: 0.2)
    }

    func testWorkRunsOnTheGivenQueueAndPassesValuesAndErrorsThrough() async throws {
        let queue = DispatchQueue(label: "com.quietframe.vault.tests.blocking-work-values")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)

        let ranOnQueue = try await BlockingWork.run(on: queue) { DispatchQueue.getSpecific(key: key) ?? false }
        let value = try await BlockingWork.run(on: queue) { 42 }

        XCTAssertTrue(ranOnQueue)
        XCTAssertEqual(value, 42)
        do {
            _ = try await BlockingWork.run(on: queue) { () throws -> Int in
                throw VaultError.thumbnailFailed
            }
            XCTFail("The work's error must reach the caller")
        } catch {
            XCTAssertEqual(error as? VaultError, .thumbnailFailed)
        }
    }
}
