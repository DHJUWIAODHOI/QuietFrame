import Foundation

enum AutoLockPeriod: Int, Codable, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .immediately: "Immediately"
        case .thirtySeconds: "After 30 Seconds"
        case .oneMinute: "After 1 Minute"
        case .fiveMinutes: "After 5 Minutes"
        }
    }
}

enum TrashRetentionPeriod: Int, Codable, CaseIterable, Identifiable, Sendable {
    case sevenDays = 7
    case fifteenDays = 15
    case thirtyDays = 30

    var id: Int { rawValue }
    var title: String { "\(rawValue) Days" }
}

enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ThumbnailSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case comfortable
    case large

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var minimumWidth: Double {
        switch self {
        case .compact: 90
        case .comfortable: 120
        case .large: 165
        }
    }
}

enum AlbumSortOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual
    case name
    case creationDate
    case modifiedDate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual"
        case .name: "Name"
        case .creationDate: "Date Created"
        case .modifiedDate: "Last Modified"
        }
    }
}
