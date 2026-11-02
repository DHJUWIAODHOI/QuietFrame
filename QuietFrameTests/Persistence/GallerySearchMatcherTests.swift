import SwiftData
import XCTest
@testable import QuietFrame

/// The search filter against a straightforward copy of the original one, which formats every date of every item.
@MainActor
final class GallerySearchMatcherTests: XCTestCase {
    private struct Configuration {
        let localeIdentifier: String
        let timeZoneIdentifier: String
    }

    private struct SampleRange {
        let year: Int
        let month: Int
        let day: Int
        let dayCount: Int
    }

    private let configurations = [
        Configuration(localeIdentifier: "en_US", timeZoneIdentifier: "America/Los_Angeles"),
        Configuration(localeIdentifier: "en_GB", timeZoneIdentifier: "Europe/London"),
        Configuration(localeIdentifier: "de_DE", timeZoneIdentifier: "Europe/Berlin"),
        Configuration(localeIdentifier: "ja_JP@calendar=japanese", timeZoneIdentifier: "Asia/Tokyo"),
        Configuration(localeIdentifier: "zh_CN@calendar=chinese", timeZoneIdentifier: "Asia/Shanghai"),
        Configuration(localeIdentifier: "he_IL@calendar=hebrew", timeZoneIdentifier: "Asia/Jerusalem"),
        Configuration(localeIdentifier: "ar_SA", timeZoneIdentifier: "Asia/Riyadh"),
        Configuration(localeIdentifier: "fa_IR", timeZoneIdentifier: "Asia/Tehran"),
        Configuration(localeIdentifier: "th_TH", timeZoneIdentifier: "Asia/Bangkok"),
        Configuration(localeIdentifier: "hi_IN", timeZoneIdentifier: "Asia/Kolkata"),
        Configuration(localeIdentifier: "en_NZ", timeZoneIdentifier: "Pacific/Chatham"),
        Configuration(localeIdentifier: "en_AU", timeZoneIdentifier: "Australia/Lord_Howe"),
        Configuration(localeIdentifier: "pt_BR", timeZoneIdentifier: "America/Sao_Paulo"),
        Configuration(localeIdentifier: "en_WS", timeZoneIdentifier: "Pacific/Apia"),
        Configuration(localeIdentifier: "en_CA", timeZoneIdentifier: "America/St_Johns")
    ]

    /// New Year, days that time-zone changes start late or skip (Samoa, 30 December 2011; Sao Paulo's midnight
    /// changes), daylight saving changes, the Japanese era change, and new years in other calendars.
    private let sampleRanges = [
        SampleRange(year: 2011, month: 12, day: 28, dayCount: 5),
        SampleRange(year: 2018, month: 11, day: 3, dayCount: 3),
        SampleRange(year: 2018, month: 12, day: 30, dayCount: 4),
        SampleRange(year: 2019, month: 2, day: 3, dayCount: 4),
        SampleRange(year: 2019, month: 2, day: 15, dayCount: 3),
        SampleRange(year: 2019, month: 3, day: 9, dayCount: 3),
        SampleRange(year: 2019, month: 3, day: 20, dayCount: 3),
        SampleRange(year: 2019, month: 3, day: 30, dayCount: 3),
        SampleRange(year: 2019, month: 4, day: 5, dayCount: 4),
        SampleRange(year: 2019, month: 4, day: 29, dayCount: 4),
        SampleRange(year: 2019, month: 9, day: 28, dayCount: 4),
        SampleRange(year: 2024, month: 2, day: 28, dayCount: 3)
    ]

    func testDateMatchesAgreeWithFormattingEveryDate() throws {
        var failures: [String] = []
        var outcomes: Set<Bool> = []
        var generator = SeededGenerator(seed: 11)
        for configuration in configurations {
            let timeZone = try XCTUnwrap(TimeZone(identifier: configuration.timeZoneIdentifier))
            let locale = Locale(identifier: configuration.localeIdentifier)
            let formatter = searchDateFormatter(locale: locale, timeZone: timeZone)
            let dates = try sampleDates(in: timeZone).shuffled(using: &generator)
            let written = dates.map { formatter.string(from: $0) }
            for search in searches(from: written) {
                var matcher = GallerySearchMatcher(search: search, dateFormatter: formatter, calendar: Calendar.current)
                for (date, text) in zip(dates, written) {
                    let expected = text.localizedCaseInsensitiveContains(search)
                    outcomes.insert(expected)
                    if matcher.dateMatches(date) != expected {
                        failures.append("\(configuration.localeIdentifier) \(timeZone.identifier) '\(search)' \(date)")
                    }
                }
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.prefix(10).joined(separator: "\n"))
        XCTAssertEqual(outcomes, [true, false])
    }

    func testMatchesAgreeWithCheckingEveryField() throws {
        let container = try makeContainer()
        let library = try makeLibrary(in: container)
        for configuration in configurations {
            let timeZone = try XCTUnwrap(TimeZone(identifier: configuration.timeZoneIdentifier))
            let locale = Locale(identifier: configuration.localeIdentifier)
            var calendar = locale.calendar
            calendar.timeZone = timeZone
            let formatter = searchDateFormatter(locale: locale, timeZone: timeZone)
            let yearItem = library.media[60]
            let year = String(calendar.component(.year, from: yearItem.importedAt))

            for search in fieldSearches + [year, "0" + year] {
                var matcher = GallerySearchMatcher(search: search, dateFormatter: formatter, calendar: calendar)
                let matched = library.media.filter { matcher.matches($0) }.map(\.id)
                let expected = library.media.filter {
                    referenceMatches($0, search: search, dateFormatter: formatter, calendar: calendar)
                }.map(\.id)
                XCTAssertEqual(matched, expected, "\(configuration.localeIdentifier) '\(search)'")
                if search == year {
                    XCTAssertTrue(expected.contains(yearItem.id), "\(configuration.localeIdentifier) '\(search)'")
                }
            }
        }
    }

    func testSearchResultsMatchTheOriginalFilterInEveryScopeAndSort() throws {
        let container = try makeContainer()
        let library = try makeLibrary(in: container)
        let repository = VaultRepository(modelContext: container.mainContext)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let calendar = Calendar.current
        let year = String(calendar.component(.year, from: library.media[60].importedAt))
        let scopes = [
            GalleryQuery(),
            GalleryQuery(sort: .name),
            GalleryQuery(filter: .favorites, sort: .createdAt, dateSortDirection: .oldestFirst),
            GalleryQuery(albumID: library.albums[0].id, sort: .size),
            GalleryQuery(collection: .favorites),
            GalleryQuery(collection: nil, sort: .type, includesTrash: true)
        ]

        for scope in scopes {
            let scopeItems = try repository.fetchMedia(query: scope, offset: 0, limit: 1_000).items
            for text in fieldSearches + [year, " \(year) ", "+\(year)"] {
                var query = scope
                query.searchText = text
                let search = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let expected = scopeItems.filter {
                    referenceMatches($0, search: search, dateFormatter: formatter, calendar: calendar)
                }.map(\.id)

                let page = try repository.fetchMedia(query: query, offset: 0, limit: 1_000)

                XCTAssertEqual(page.items.map(\.id), expected, "'\(text)' in \(scope)")
                XCTAssertFalse(page.hasMore)
            }
        }
    }

    /// The original search filter, field by field.
    private func referenceMatches(
        _ media: VaultMedia,
        search: String,
        dateFormatter: DateFormatter,
        calendar: Calendar
    ) -> Bool {
        media.originalFilename?.localizedCaseInsensitiveContains(search) == true
            || media.album?.name.localizedCaseInsensitiveContains(search) == true
            || media.tags.contains(where: { $0.localizedCaseInsensitiveContains(search) })
            || dateFormatter.string(from: media.importedAt).localizedCaseInsensitiveContains(search)
            || media.originalCreationDate.map {
                dateFormatter.string(from: $0).localizedCaseInsensitiveContains(search)
            } == true
            || Int(calendar.component(.year, from: media.importedAt)).description == search
    }

    private struct Library {
        let albums: [VaultAlbum]
        let media: [VaultMedia]
    }

    /// Filenames, album names and tags that overlap with month names and numbers, so every field decides some
    /// matches, and year-like searches that only an exact year spelling should match.
    private let fieldSearches = [
        "IMG_1", "holiday", "Beach", "sunset 1", "may", "MAR", "Family", "2019", "2020", "1", "31", "36",
        "02019", "+2019", "-1", "1440", "2562", "zzz"
    ]

    private func makeLibrary(in container: ModelContainer) throws -> Library {
        let context = container.mainContext
        let albums = ["Holiday 2019", "Family", "Mayday"].enumerated().map { index, name in
            VaultAlbum(name: name, position: index)
        }
        albums.forEach { context.insert($0) }
        try context.save()

        let start = Date(timeIntervalSince1970: 1_546_120_800)
        var media: [VaultMedia] = []
        for index in 0..<120 {
            let creationDate: Date? = index % 3 == 0 ? nil : start.addingTimeInterval(TimeInterval(-index * 50_311))
            let item = VaultMedia(
                storageIdentifier: String(format: "item-%03ld", index),
                contentFingerprint: "fingerprint-\(index)",
                metadata: MediaMetadata(
                    mediaType: index % 9 == 0 ? .video : .photo,
                    contentTypeIdentifier: "public.jpeg",
                    originalFilename: index % 7 == 0 ? nil : "IMG_\(index).JPG",
                    originalCreationDate: creationDate,
                    pixelWidth: 10,
                    pixelHeight: 10,
                    duration: nil,
                    byteCount: Int64(1_000 + index % 11)
                ),
                importedAt: start.addingTimeInterval(TimeInterval(index * 412_337)),
                isFavorite: index % 4 == 0,
                tags: index % 5 == 0 ? ["Beach", "Sunset \(index)"] : [],
                album: index % 4 == 3 ? nil : albums[index % albums.count]
            )
            if index % 8 == 7 {
                item.trashedAt = start
            }
            context.insert(item)
            media.append(item)
        }
        try context.save()
        return Library(albums: albums, media: media)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([VaultMedia.self, VaultAlbum.self, AppSettings.self, ImportRecord.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func searchDateFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    /// Moments just before, at and after each local midnight, at noon, at the day's last second, and every 187
    /// minutes in between.
    private func sampleDates(in timeZone: TimeZone) throws -> [Date] {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        var dates: [Date] = []
        for range in sampleRanges {
            let components = DateComponents(year: range.year, month: range.month, day: range.day, hour: 12)
            let firstNoon = try XCTUnwrap(gregorian.date(from: components))
            for offset in 0..<range.dayCount {
                let noon = try XCTUnwrap(gregorian.date(byAdding: .day, value: offset, to: firstNoon))
                let start = gregorian.startOfDay(for: noon)
                let nextStart = gregorian.startOfDay(for: start.addingTimeInterval(30 * 3_600))
                dates += [start.addingTimeInterval(-1), start, start.addingTimeInterval(1), noon]
                dates.append(nextStart.addingTimeInterval(-1))
                var moment = start.addingTimeInterval(187 * 60)
                while moment < nextStart {
                    dates.append(moment)
                    moment = moment.addingTimeInterval(187 * 60)
                }
            }
        }
        return dates
    }

    /// Whole written dates and pieces of them, so some searches match single days, plus fixed ones.
    private func searches(from written: [String]) -> [String] {
        var searches = ["1", "30", "2019", "May", "zzz"]
        if let first = written.first, let last = written.last {
            for text in [first, written[written.count / 2], last] {
                searches += [text, String(text.prefix(3)), String(text.suffix(4))]
            }
        }
        return searches
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
