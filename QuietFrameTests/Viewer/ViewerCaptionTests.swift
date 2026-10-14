import XCTest
@testable import QuietFrame

final class ViewerCaptionTests: XCTestCase {
    private let british = Locale(identifier: "en_GB")

    func testCaptionShowsBritishDateOverWeekdayAndTime() throws {
        let date = try makeDate(year: 2026, month: 3, day: 12, hour: 18, minute: 42)

        let caption = viewerCaption(for: date, locale: british, timeZone: .gmt)

        XCTAssertEqual(caption.title, "12 March 2026")
        XCTAssertEqual(caption.subtitle, "Thursday at 18:42")
    }

    func testCaptionFollowsTheLocaleDateOrder() throws {
        let date = try makeDate(year: 2026, month: 3, day: 12, hour: 18, minute: 42)

        let caption = viewerCaption(for: date, locale: Locale(identifier: "en_US"), timeZone: .gmt)

        XCTAssertEqual(caption.title, "March 12, 2026")
        XCTAssertTrue(caption.subtitle.hasPrefix("Thursday at 6:42"))
    }

    func testCaptionFollowsTheTimeZone() throws {
        let date = try makeDate(year: 2026, month: 3, day: 12, hour: 23, minute: 30)
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))

        let caption = viewerCaption(for: date, locale: british, timeZone: tokyo)

        XCTAssertEqual(caption.title, "13 March 2026")
        XCTAssertEqual(caption.subtitle, "Friday at 08:30")
    }

    func testLongDateNamesTheWeekdayDateAndTime() throws {
        let date = try makeDate(year: 2026, month: 3, day: 12, hour: 18, minute: 42)

        let text = viewerLongDate(date, locale: british, timeZone: .gmt)

        XCTAssertTrue(text.hasPrefix("Thursday"))
        XCTAssertTrue(text.contains("12 March 2026"))
        XCTAssertTrue(text.hasSuffix(" at 18:42"))
    }

    func testPlaybackTimeShowsMinutesAndSeconds() {
        XCTAssertEqual(formattedPlaybackTime(0), "0:00")
        XCTAssertEqual(formattedPlaybackTime(14), "0:14")
        XCTAssertEqual(formattedPlaybackTime(14.9), "0:14")
        XCTAssertEqual(formattedPlaybackTime(62), "1:02")
    }

    func testPlaybackTimeShowsHoursForLongVideos() {
        XCTAssertEqual(formattedPlaybackTime(3_723), "1:02:03")
        XCTAssertEqual(formattedPlaybackTime(3_600), "1:00:00")
    }

    func testPlaybackTimeTreatsInvalidValuesAsZero() {
        XCTAssertEqual(formattedPlaybackTime(-5), "0:00")
        XCTAssertEqual(formattedPlaybackTime(.nan), "0:00")
        XCTAssertEqual(formattedPlaybackTime(.infinity), "0:00")
        XCTAssertEqual(formattedPlaybackTime(-.infinity), "0:00")
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return try XCTUnwrap(calendar.date(from: components))
    }
}
