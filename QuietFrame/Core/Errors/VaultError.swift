import Foundation

enum VaultError: Error, LocalizedError, Equatable, Sendable {
    case authenticationFailed
    case authenticationRequired
    case invalidPasscode
    case passcodesDoNotMatch
    case temporarilyLocked(until: Date)
    case biometricsUnavailable
    case biometricsChanged
    case keychainFailure
    case missingEncryptionKey
    case corruptedFile
    case unsupportedFileType
    case duplicateMedia
    case insufficientStorage
    case importFailed
    case importCancelled
    case exportFailed
    case photosPermissionDenied
    case limitedPhotosAccess
    case thumbnailFailed
    case persistenceFailure
    case migrationFailed
    case fileOperationFailed
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed: "Authentication was not successful. Please try again."
        case .authenticationRequired: "Unlock QuietFrame to continue."
        case .invalidPasscode: "Enter the correct six-digit passcode."
        case .passcodesDoNotMatch: "The passcodes do not match."
        case .temporarilyLocked(let date):
            "Too many attempts. Try again \(date.formatted(.relative(presentation: .named)))."
        case .biometricsUnavailable: "Biometric authentication is not available."
        case .biometricsChanged: "Biometric data changed. Unlock with your passcode, then enable biometrics again in Settings."
        case .keychainFailure: "Secure credentials could not be accessed."
        case .missingEncryptionKey: "The vault encryption key is unavailable. Your media was not changed."
        case .corruptedFile: "This item could not be verified or opened."
        case .unsupportedFileType: "This media type is not supported."
        case .duplicateMedia: "This item is already in QuietFrame."
        case .insufficientStorage: "There is not enough free device storage to complete this action."
        case .importFailed: "The media could not be imported."
        case .importCancelled: "The import was cancelled."
        case .exportFailed: "The media could not be exported."
        case .photosPermissionDenied: "Photos access was denied. You can change it in Settings."
        case .limitedPhotosAccess: "Only selected Photos items are available."
        case .thumbnailFailed: "A preview could not be created."
        case .persistenceFailure: "Vault changes could not be saved."
        case .migrationFailed: "The local vault database could not be opened."
        case .fileOperationFailed: "The secure file operation could not be completed."
        case .invalidInput(let message): message
        }
    }
}
