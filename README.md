# QuietFrame

QuietFrame is an original, local-only iOS photo and video vault built with SwiftUI, SwiftData, CryptoKit, PhotosUI, PhotoKit, AVFoundation, LocalAuthentication, and Keychain Services. It has no account system, network client, analytics, advertising, or third-party dependencies.

The app targets iOS 17 or later and uses the installed iOS SDK, so it can be built with the latest stable Xcode while retaining iOS 17 compatibility.

## Build Status

The project and shared scheme are checked in at `QuietFrame.xcodeproj`. All source, resource, unit-test, and UI-test targets are present.

The GitHub Actions macOS workflow (Xcode 16.4) runs the full unit and UI test suite on an iPhone 16 Pro simulator, runs the SwiftData tests again on iOS 18.5, runs the performance benchmarks in a separate optimized step, archives an unsigned device build and publishes the IPA, and finally runs the SwiftData tests on an installed iOS 17.5 simulator. It runs on every push to `main` and on manual dispatch.

## Setup

1. Install the latest stable Xcode that supports iOS 17 or later.
2. Open `QuietFrame.xcodeproj`.
3. Select the `QuietFrame` target and choose your Apple development team.
4. Change `com.quietframe.vault` if your team needs a different bundle identifier.
5. Select an iOS 17 or newer simulator or device.
6. Build and run the shared `QuietFrame` scheme.

No package resolution or dependency installation is required.

Command-line verification on macOS:

```bash
xcodebuild -project QuietFrame.xcodeproj \
  -scheme QuietFrame \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  clean build

xcodebuild -project QuietFrame.xcodeproj \
  -scheme QuietFrame \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test
```

For a signing-independent Release compile check:

```bash
xcodebuild -project QuietFrame.xcodeproj \
  -scheme QuietFrame \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  clean build
```

## Product Design

QuietFrame uses a graphite and indigo visual language, an original viewfinder mark, system typography, SF Symbols, adaptive light/dark appearances, Dynamic Type, Reduce Motion handling, native navigation, and a four-tab structure:

- Vault
- Albums
- Trash
- Settings

The app icon has original light, dark, and tinted SVG artwork. Xcode asset-catalog compilation and archive validation must confirm direct `.appiconset` SVG support in the selected Xcode release. If `actool` rejects SVG app icons, export the supplied full-bleed 1024 x 1024 artwork to opaque PNG without changing the design and update `Contents.json`.

## Architecture

QuietFrame follows MVVM and protocol-based dependency injection:

```text
QuietFrame/
  App/             composition root, lifecycle, lock coordinator
  Components/      reusable SwiftUI and UIKit bridges
  Core/            theme, errors, extensions, haptics
  Features/        authentication, import, gallery, albums, viewer,
                   trash, settings, and storage UI
  Models/          SwiftData models and domain value types
  Persistence/     versioned schema and repository
  Security/        Keychain, passcode KDF, session, crypto, storage,
                   reset journal, and temporary leases
  Services/        import/export, Photos, albums, trash, thumbnails,
                   reconciliation, metadata, and storage analysis
  Resources/       assets, entitlements, and privacy manifest
QuietFrameTests/   unit tests and mocks
QuietFrameUITests/ authentication-gate UI test
```

`AppDependencies` constructs concrete services once and injects them into feature view models. SwiftData operations are confined to the main actor. Encryption, file processing, metadata extraction, thumbnail generation, Photos operations, and protected storage are actor-isolated and use async/await.

The root view renders `MainTabView` only while `VaultLockCoordinator.State` is `.unlocked`. Locked, onboarding, and recovery states replace the navigation hierarchy instead of overlaying an unlock sheet, preventing navigation-state bypass.

## Data Model

The current SwiftData schema is V3. V1 and V2 stores migrate in place through `VaultMigrationPlan`. It contains:

- `VaultMedia`: opaque storage IDs, keyed duplicate token, media metadata, favorite state, tags, album relation, and trash state
- `VaultAlbum`: name, dates, manual position, cover ID, and media relation
- `AppSettings`: biometric preference, auto-lock, retention, appearance, thumbnail size, and album sort
- `ImportRecord`: import counts, state, and timestamps

All Media, Recently Added, and Favorites are computed smart collections. Recently Added currently means imported within the last 30 days.

Media bytes and thumbnails are never stored in SwiftData.

## Security Design

### Optional passcode and master key

1. Setup generates a random 256-bit master key with `SecRandomCopyBytes`.
2. Users may protect access with a six-digit app passcode or continue without one.
3. With a passcode, a random 128-bit salt and PBKDF2-HMAC-SHA256 with 210,000 iterations derive a wrapping key.
4. AES-GCM wraps the master key with authenticated context data.
5. Without a passcode, the random master key is stored directly in the device-only Keychain and restored silently while the iPhone is unlocked.
6. Keychain items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and are explicitly non-synchronizing.
7. The passcode itself is never stored.
8. Failed attempts persist in Keychain and produce escalating delays up to one hour.

An unlocked master key exists only in the actor-isolated `VaultSession`. Lock increments a session generation and removes the key. Every encryption/decryption chunk validates that generation, so work started by a prior unlocked session is revoked at the next chunk boundary.

### Biometrics

Biometric unlock is opt-in and requires fresh biometric authentication when enabled. A second master-key item uses:

- `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`
- `SecAccessControlCreateFlags.biometryCurrentSet`

Changing enrolled biometrics invalidates that item. QuietFrame disables its biometric setting and requires passcode unlock plus explicit re-enrollment.

### Encrypted container

Each encrypted file has a 48-byte authenticated header:

- format magic and version
- chunk size
- plaintext length
- random 128-bit per-file HKDF salt
- random 64-bit nonce prefix

HKDF-SHA256 derives a separate 256-bit content key for each file from the master key and salt. Files are processed in 1 MiB chunks. Each chunk uses AES-GCM with a 96-bit nonce made from the random file prefix plus a 32-bit chunk index. The complete header and chunk index are authenticated additional data. Every chunk has its own 128-bit GCM tag.

This detects modified headers, altered chunks, truncation, appended data, and chunk-position substitution while keeping memory bounded for large videos.

### Duplicate detection

The plaintext SHA-256 digest is not persisted directly. QuietFrame HMACs that digest with a master-key-derived deduplication key and stores only the keyed token. Exact byte-identical files in the same vault match; re-encoded or edited copies do not.

### File storage

- Encrypted originals use opaque UUID filenames in `Library/Application Support/QuietFrameVault/media`.
- Trashed originals are moved to an encrypted `trash` directory without decryption.
- Thumbnails are encrypted separately.
- Imports first write a protected random `.partial` container and move it only after encryption succeeds.
- All sensitive directories and files use `NSFileProtectionComplete`.
- The target has `com.apple.developer.default-data-protection = NSFileProtectionComplete`.
- Media, metadata-store directories, SQLite/WAL/SHM files, staging, caches, and temporary files are excluded from backup.
- Storage identifiers are validated UUIDs, and original filenames are not used in sandbox paths.

SwiftData metadata is protected by iOS complete Data Protection and backup exclusion but is not application-level encrypted with the QuietFrame passcode. See Known Limitations.

### Decrypted temporary files

Photos decrypt in memory and decode at the size the screen shows them; zooming decodes the selected photo again at up to 4096 pixels. Videos play straight from their encrypted files: AVFoundation reads byte ranges through a private resource loader, and each chunk is decrypted and authenticated in memory as it is read, so playback writes no plaintext. Native export (Share and Save to Photos) still requires a file URL, so QuietFrame creates protected, backup-excluded, randomly named temporary files for it. `SecureTemporaryFileLease` deletes them explicitly and on deinitialization. Lock clears exports, staging files, incoming Photos transfers, and the thumbnail memory cache.

### Reset

Reset requires multiple UI confirmations and authentication. QuietFrame writes a protected reset journal, locks and cancels media work, deletes Keychain key access first, removes encrypted files, deletes metadata, and then clears the journal. If the process stops mid-reset, bootstrap detects the journal before opening SwiftData and idempotently deletes credentials, store/WAL/SHM files, encrypted roots, and temporary roots.

A forgotten passcode or missing key cannot recover media. Users may authenticate as the iOS device owner to erase the unrecoverable vault and start over; that authorization permits deletion only.

## Permissions

QuietFrame requests no permission on launch.

- Photos picker import starts only after the user taps Import. QuietFrame requests read/write Photos access then so PhotoKit can inspect and revalidate the exact selected originals for optional deletion.
- `NSPhotoLibraryUsageDescription` explains that user-initiated request. Import can continue through the system picker if access is denied, but deletion is unavailable when QuietFrame cannot validate the corresponding assets.
- `NSPhotoLibraryAddUsageDescription` is used only when the user explicitly saves media back to Photos.
- `NSFaceIDUsageDescription` explains biometric vault unlock.

Original Photos assets are never deleted automatically. The import summary offers deletion only when every successfully imported item maps to an exact, unadjusted, single-resource Photos asset. QuietFrame revalidates those assets, presents a destructive confirmation, and explains that items may remain in Recently Deleted.

## Implemented Features

- Privacy onboarding with a choice between six-digit passcode protection and no app passcode
- Passcode setup/removal later from Settings without re-encrypting media
- Passcode unlock, change, escalating lockout, manual lock, and configurable auto-lock
- Face ID and Touch ID opt-in with current-enrollment invalidation
- App-switcher privacy cover and active-capture lock
- Device-authenticated destructive recovery for forgotten/missing keys
- Multi-item Photos picker with review, metadata extraction, encrypted thumbnails, progress, cancellation, duplicate detection, and import summary
- Explicit optional deletion of imported Photos originals
- Chunked authenticated encryption for every original and thumbnail
- Opaque protected sandbox storage and backup exclusion
- All Media, Recently Added, Favorites, and user albums
- Album create, rename, delete, cover, move, count, and sort operations
- Paged adaptive lazy gallery with photo/video/favorite filters and five sort modes
- Search by filename, album, import/creation date, year, and optional tags
- Multi-selection with favorite, move, export, and Trash actions
- Swipe viewer with swipe-down dismissal, photo pinch/double-tap zoom, tap-to-play looping video with unobstructed native controls, favorite, move, export, Trash, and information panel
- Encrypted Trash with deletion dates, restoration, permanent deletion, Empty Trash, and 7/15/30-day purge
- Native multi-item share sheet and original-byte Photos export
- Settings for biometrics, passcode, lock timing, Trash retention, appearance, thumbnail size, storage, privacy, export behavior, manual lock, and reset
- Storage totals for photos, videos, previews, Trash, item/album counts, and largest-file discovery
- Startup reconciliation for interrupted moves and encrypted orphans
- Dynamic Type, VoiceOver labels/actions, Reduce Motion, light/dark mode, and haptic feedback
- Privacy manifest declaring no tracking or collected data

## Tests

The unit target contains 377 tests in 47 files, covering:

- PBKDF2 against independent vectors, including a full 210,000-iteration comparison with the previous implementation
- passcode creation, unlock, wrong attempts, lockout, change, reset, and the storage check that runs after unlock
- Keychain create/update/read/delete
- the encrypted container format against documented vectors, multi-chunk round trips, tampering, truncation, padding, oversized headers, and revocation on lock
- encrypted video streaming end to end through AVFoundation, with no plaintext written to disk
- secure storage, bulk listings and batch moves and deletes, and temporary lease cleanup
- library queries, paging, search results across locales and time zones, and skipped refreshes
- thumbnail decoding, caching, prefetch and cancellation, and the viewer's photo loader
- video playback and scrubbing
- import preparation, progress, in-memory thumbnail encryption, per-item cleanup, previews, and duplicate detection
- albums, Album counts, Trash, retention purge, reconciliation, and storage analysis
- on-disk migrations from V1 and V2 to V3

49 performance benchmarks in 11 classes live in `QuietFrameTests/Benchmarks`. CI runs them in their own optimized step, and `Docs/Performance/PROGRESS.md` records the results.

The UI target verifies that launch cannot expose the tab hierarchy before onboarding, unlock, or recovery authentication.

Tests use in-memory SwiftData stores and protocol mocks. Security file tests use isolated temporary directories and deterministic representative data; no test key is used by production code.

## Known Limitations and Remaining Release Work

1. XCTest execution, Simulator testing, and physical-device testing have not been run in this Windows environment. The unsigned device archive is built by GitHub Actions with Xcode 16.4.
2. Xcode 16.4 archives the supplied SVG icons but emits app-icon extension warnings. Convert them to full-bleed PNG before App Store submission.
3. A six-digit passcode has at most one million combinations. PBKDF2 slows guesses, and iOS sandbox/Keychain controls protect the envelope, but an extracted envelope has a limited offline search space. There is no alphanumeric passphrase option in v1.
4. Choosing no app passcode means anyone using the unlocked iPhone can open QuietFrame. Media remains encrypted at rest by a random key in the device-only Keychain.
5. The normal passcode envelope uses `WhenUnlockedThisDeviceOnly`, not `WhenPasscodeSetThisDeviceOnly`. QuietFrame should either require an iOS device passcode in a future security-policy revision or explicitly accept operation on devices without one.
6. SwiftData catalog metadata is plaintext inside an OS-protected, backup-excluded store. The app passcode encrypts media and thumbnails, not filenames, albums, dates, dimensions, sizes, tags, or SQLite free pages while the device is already unlocked.
7. Share and Save to Photos decrypt a protected temporary copy first, so very large videos need free space approximately equal to their size plus a safety margin. Playback streams from the encrypted file and needs no free space.
8. Bulk sharing decrypts all selected files before presenting the activity sheet. Each file receives a capacity check, but v1 has no aggregate progress UI.
9. Search scans the scoped metadata set for multi-field matching on its first page; later pages reuse that result until the library changes. Very large vaults still pay that first scan.
10. Viewer swipe navigation covers currently loaded gallery pages. It does not yet fetch the next metadata page from inside the viewer.
11. Tags are represented, displayed, and searchable but v1 has no tag editing screen.
12. Failed import thumbnails remain as placeholders; there is no background thumbnail-regeneration queue.
13. Live Photos, bursts, RAW workflows, and animated-image semantics are not preserved as compound Photos-library assets. The picker imports an image or movie representation, and automatic source deletion is unavailable for adjusted or multi-resource assets.
14. Exact duplicate detection does not detect visually similar, edited, or re-encoded media.
15. Trash expiration runs when QuietFrame unlocks or Trash opens; iOS may not run the app exactly at a deadline.
16. Random export paths intentionally avoid exposing original filenames. Native share recipients receive random filenames with the correct extension.
17. Once a user hands a decrypted item to Photos or an activity extension, the destination may retain, upload, thumbnail, sync, or back up its copy. QuietFrame cannot control that behavior.
18. iOS has no public API that fully blocks screenshots. QuietFrame covers inactive snapshots and locks on active capture, but screenshot notification is post-capture.
19. APFS and flash storage do not support verifiable application-level secure overwrite. Reset relies primarily on cryptographic key destruction.
20. The metadata schema is at V3. V1 and V2 stores migrate in place, and on-disk migration tests cover both stages.
21. Localization is English-only in v1.

## Release Checklist

- Run Debug and Release builds with the latest stable Xcode.
- CI runs every unit and UI test on the latest iOS simulator and the SwiftData tests on iOS 18.5 and 17.5. Run the full suite on an iOS 17 simulator or device before relying on it there.
- Exercise Face ID/Touch ID, device lock, enrollment changes, background transitions, Photos limited access, denied permissions, and low-storage behavior on physical devices.
- Validate the app icon, launch screen, privacy manifest, and signing for your own install. QuietFrame is for personal use and is not published to the App Store.
- Use Accessibility Inspector with VoiceOver, maximum Dynamic Type, Increase Contrast, Reduce Motion, landscape, iPad split view, and keyboard navigation.
- Use Instruments with thousands of metadata records, large HEIC/JPEG images, and multi-gigabyte videos.
- Review `SECURITY.md` and `Docs/PHASE_REPORT.md` before release.

## License

No license has been selected. Add the intended license before public distribution.
