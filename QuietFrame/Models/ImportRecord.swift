import Foundation
import SwiftData

enum ImportStatus: String, Codable, Sendable {
    case running
    case completed
    case cancelled
    case failed
}

@Model
final class ImportRecord {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var finishedAt: Date?
    var requestedCount: Int
    var importedCount: Int
    var duplicateCount: Int
    var failedCount: Int
    var statusRawValue: String

    init(id: UUID = UUID(), requestedCount: Int) {
        self.id = id
        self.startedAt = Date()
        self.requestedCount = requestedCount
        self.importedCount = 0
        self.duplicateCount = 0
        self.failedCount = 0
        self.statusRawValue = ImportStatus.running.rawValue
    }

    var status: ImportStatus {
        get { ImportStatus(rawValue: statusRawValue) ?? .failed }
        set { statusRawValue = newValue.rawValue }
    }
}
