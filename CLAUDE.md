# CLAUDE.md

QuietFrame is a local-only iOS 17+ photo/video vault: SwiftUI, SwiftData, CryptoKit, PhotosUI/PhotoKit, AVFoundation, LocalAuthentication, Keychain. No third-party dependencies, networking, analytics, or logging. Bundle ID `com.quietframe.vault`.

Read `README.md` (features, known limitations) and `SECURITY.md` (threat model) before security-sensitive work. Both are partly stale; see Status.

## Environment

- The dev machine is **Windows with no Xcode**. Nothing can be built or tested locally. Verify with careful static review, then CI.
- CI: `.github/workflows/build-ipa.yml` (macos-15, Xcode not pinned) runs on every push to `main` and on manual dispatch. It runs the full `xcodebuild test` (ad-hoc signed) on an iPhone 16 Pro simulator, then builds an unsigned Release archive and uploads it as an unsigned IPA. On failure it prints an xcresult summary and uploads the log and `.xcresult`. **Pushing to `main` triggers it.** Check runs with `gh run list -R DHJUWIAODHOI/QuietFrame`.
- Downloaded CI IPAs live in `Artifacts/<artifact>-<sha>/` (gitignored).
- `opencode.json`, `package.json`, `package-lock.json` and `node_modules/` at the root are leftover opencode tooling, not part of the app. Never commit them.

## Commands (macOS)

```bash
# Build
xcodebuild -project QuietFrame.xcodeproj -scheme QuietFrame -configuration Debug \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' \
  CODE_SIGNING_ALLOWED=NO build

# All tests (same as CI)
xcodebuild -project QuietFrame.xcodeproj -scheme QuietFrame -configuration Debug \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' \
  CODE_SIGNING_ALLOWED=NO test

# One class or method: append to the test command
#   -only-testing:QuietFrameTests/AuthenticationServiceTests
#   -only-testing:QuietFrameTests/AuthenticationServiceTests/testWrongPasscodeDoesNotUnlockSession

# Signing-free Release compile check
xcodebuild -project QuietFrame.xcodeproj -scheme QuietFrame -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO clean build
```

Run: open `QuietFrame.xcodeproj`, set a development team on the `QuietFrame` target, and run the shared `QuietFrame` scheme on an iOS 17+ simulator or device.

## Project facts

- Xcode 16+ project (objectVersion 77) with **file-system-synchronized groups**. Any `.swift` file under `QuietFrame/`, `QuietFrameTests/` or `QuietFrameUITests/` is automatically in that target. Don't edit `project.pbxproj` to add files.
- There is no Info.plist file. It is generated from `INFOPLIST_KEY_*` build settings in `project.pbxproj`, which is where the Face ID, Photos and Photos-add usage strings live.
- iOS 17.0 deployment target, `SWIFT_VERSION = 5.0`, no strict-concurrency setting, iPhone and iPad (`TARGETED_DEVICE_FAMILY = 1,2`).
- Entitlement: default data protection is `NSFileProtectionComplete`. `PrivacyInfo.xcprivacy` declares DiskSpace `E174.1` and FileTimestamp `C617.1`. Update it whenever you use another required-reason API.
- Unit tests are hosted in the app (TEST_HOST). XCTest only, not Swift Testing.

## Architecture

```
QuietFrame/
  App/          QuietFrameApp, AppModel (bootstrap), AppDependencies (composition root),
                RootView, MainTabView, VaultLockCoordinator (lock state machine)
  Security/     AuthenticationService, VaultSession, ChunkedEncryptionService,
                SecureFileStorageService, KeychainService, PBKDF2, AppResetJournal,
                SecureTemporaryFileLease
  Services/     import/export/Photos/metadata/thumbnails (actors); albums/trash/
                reconciliation/storage analysis (@MainActor); VaultOperationGate
  Persistence/  VaultRepository, VaultSchema (V1 -> V2 -> V3 + VaultMigrationPlan)
  Models/       @Models (VaultMedia, VaultAlbum, AppSettings, ImportRecord) + value types
  Features/     Authentication, Vault, Gallery, Viewer, Albums, Import, Trash, Settings
  Components/   reusable SwiftUI views and UIKit bridges
  Core/         QuietFrameTheme, VaultError, Data/FileHandle extensions, haptics
  Resources/    assets, entitlements, privacy manifest
```

- **Bootstrap** (`AppModel`):
  1. Finish any pending reset journal.
  2. Protect Application Support and exclude it from backup.
  3. Open the `ModelContainer` with the migration plan.
  4. Seed the `AppSettings` singleton.
  5. Build `AppDependencies`.
- **DI:** `AppDependencies` builds every service once. It is injected with `.environment(dependencies)` and read with `@Environment(AppDependencies.self)`. Services get protocol-typed dependencies through their initializers.
- **Lock boundary:** `RootView` swaps the entire view tree based on `VaultLockCoordinator.State`. `MainTabView` exists only while `.unlocked`; it has 4 tabs (Vault, Albums, Trash, Settings), each with its own `NavigationStack`. Never show vault content as an overlay on a locked state.
- **Concurrency:** SwiftData is used only from `@MainActor` types, through `modelContainer.mainContext`. Crypto, file and Photos work runs in actors. Pass UUIDs or plain value snapshots across actor boundaries, never `@Model` objects.
- **VaultOperationGate:** one shared async mutex. It is FIFO and **not reentrant**. It runs import, all trash operations, album delete, reconcile, reset and export one at a time. Code that already holds the gate calls the private `*Exclusively` helpers.
- **On disk:**
  - Encrypted files: `Application Support/QuietFrameVault/{media,thumbnails,trash}/<uuid>.qfe`
  - In-progress encryption: `.../staging/<uuid>.partial`
  - Decrypted temp files: `Caches/QuietFrameTemporary/`
  - Picker copies: `tmp/QuietFrameIncoming/`
  - SwiftData: `default.store` in Application Support
  - Reset marker: `Application Support/reset-in-progress`
- **Consistency rules:**
  - Moves (trash, restore, album delete): move the files first, then save metadata. If the save fails, move the files back.
  - Deletes: remove metadata first, then files.
  - `StorageReconciliationService` runs after every unlock as a backstop.

## Security invariants (do not regress)

- **Master key:** 32 bytes from `SecRandomCopyBytes`, held only in the `VaultSession` actor while unlocked.
- **Passcode:** PBKDF2-HMAC-SHA256 (210,000 iterations, 16-byte salt) produces the key that wraps the master key with AES-GCM. A constant-time HMAC verifier checks the passcode. The passcode is never stored.
- **Keychain:** service `com.quietframe.vault.security`; every item is `WhenUnlockedThisDeviceOnly` and non-synchronizable. The biometric item is `WhenPasscodeSetThisDeviceOnly` + `.biometryCurrentSet`.
- **Media encryption:** chunked AES-256-GCM container (`QFRAME01` v1, 1 MiB chunks, per-file HKDF key, header + chunk index as AAD). Crypto loops check the session generation on every chunk so locking cancels work in progress.
- **Versioned identifiers:** `QuietFrame.<purpose>.v1` strings, `<name>-v1` Keychain accounts, and the container magic and version must never change in place. Add a new version and migrate.
- **Files:** every file and directory the app creates gets `FileProtectionType.complete` and `isExcludedFromBackup`, and a random UUID name, never the original filename.
- **SwiftData:** media bytes and thumbnails never go into it. The metadata in it is plaintext and protected only by iOS (a known, documented boundary).
- **Photos library:** write to it only on an explicit "Save to Photos". Delete originals only through the confirmed, revalidated flow.
- **Never add:** networking, logging (`print`/`os_log`/`Logger`), analytics, `UserDefaults`/`@AppStorage`, or third-party dependencies. Settings live in the SwiftData `AppSettings` singleton; secrets live in the Keychain.

## Conventions

- Use `@MainActor @Observable final class` for UI state and anything that touches SwiftData. Use `actor` for crypto, file and Photos services. Observation only: no `ObservableObject`, `@StateObject` or `@AppStorage`.
- Give every service a protocol for mocking (`AuthenticationServicing`, `KeychainServing`, `SecureFileStoring`, `MediaImporting`, `VaultRepositoryProtocol`, ...). Inject time and cross-service hooks as closures (`now:`, `postUnlockMaintenance:`, `cancelMediaOperations:`).
- **Errors:** use the single `VaultError` enum, which carries user-facing strings. In the UI, map with `(error as? VaultError)?.localizedDescription ?? VaultError.<fallback>.localizedDescription`, keep it in `userMessage: String?`, and show it with `.alert("QuietFrame", ...)`.
- **SwiftData saves:** `do { try modelContext.save() } catch { modelContext.rollback(); throw VaultError.persistenceFailure }`. Store enums as raw `String`/`Int` columns with typed computed accessors.
- **Schema changes:**
  1. Add `VaultSchemaVN`.
  2. Freeze the previous version as nested copies.
  3. Add a stage to `VaultMigrationPlan`.
  4. Add an on-disk migration test.
- The code has zero force unwraps, `try!`, `as!` and `fatalError`; keep it that way. Use `try?` only for best-effort cleanup.
- **Views:**
  - A screen with a view model creates it in a private `*Content` struct via `State(initialValue:)`; child views take it as `@Bindable`. Simple screens use `@Query` and call services directly.
  - Naming: tab roots are `*Screen`, other views are `*View`, design primitives are `Quiet*`, UIKit bridges are `*View: UIViewRepresentable` with a nested `Coordinator`.
- **Design:**
  - Use `QuietFrameTheme` tokens: corner radius 20/12, page padding 20, spacing 28/16/8, control height 44, readable width 560. Use `.quietCard()` and `.quietFormStyle()`.
  - Use system text styles only, and `.monospacedDigit()` for numbers.
  - Support Dynamic Type (branch on `isAccessibilitySize`, use `ViewThatFits`) and Reduce Motion. For VoiceOver, use `accessibilityAction(named:)` to mirror long-press and context-menu actions.
- Accessibility identifiers are kebab-case (`onboarding`, `unlock-screen`, `main-tabs`, ...), and the UI test depends on them.
- Comments are rare; write self-explanatory code.
- **Tests:**
  - XCTest with `@MainActor` test classes and an in-memory `ModelContainer`.
  - Mocks live in `QuietFrameTests/TestSupport/`.
  - Use low PBKDF2 cost via `AuthenticationService.Policy`, and temp dirs with `applyFileProtection: false`.
- **Commits:** small and focused, with imperative subjects ("Add ...", "Fix ...", "Simplify ...").

## Status (2026-10-08)

- The v1 feature set is implemented. There are no TODO/FIXME markers; open work is in README "Known Limitations" and the unchecked items of the SECURITY.md checklist.
- `main` and `origin/main` are in sync. CI runs the full test suite and passes (run 37814853905, commit `261e0f4`). The simulator test step must stay ad-hoc signed (`CODE_SIGN_IDENTITY=-`): an unsigned test host has no Keychain access, which fails `KeychainServiceTests` and leaves the UI test on the retry screen. `refactor-ui-fork` (= `fork/main`) is an older branch with a shortened CI test list.
- **Tests:** 88 unit tests in 19 files, plus 1 UI test. No tests cover reset-journal recovery, thumbnails, metadata extraction, ImportViewModel, biometrics, iterated PBKDF2, or most container tamper cases.
- **Stale docs:**
  - README: says 28 tests and a V1 schema, and claims CI doesn't run the tests.
  - SECURITY.md:26: says Apple has no PBKDF2 API.
  - SECURITY.md:63: says no operation gate exists.
  - PHASE_REPORT.md:114: says the viewer decrypts only the active page. Photos are now prepared for the selected page and its neighbours, one at a time, by `ViewerPhotoLoader`; videos are decrypted only for the active page.
- **Half-finished:**
  - Tags can be searched, but nothing creates them.
  - `ImportRecord` is never read.
  - No thumbnail regeneration.
  - The viewer can't page past the loaded gallery items.
  - No bulk unfavorite.

### Known issues (verified; remove each one when it is fixed)
- With the default "Immediately", auto-lock fires on the app's own system prompts: Face ID enable, Photos permission, the delete confirmation, Save to Photos (`App/VaultLockCoordinator.swift:324`).
- Backgrounding during an in-flight unlock leaves the vault unlocked past the auto-lock grace period (`VaultLockCoordinator.swift:324-358`).
- Any reconcile or purge failure blocks unlock, and the user sees an authentication error (`App/AppDependencies.swift:95`).
- "Delete from Photos" doesn't warn that the backup-excluded vault becomes the only copy (`Features/Import/ImportPreviewView.swift:58`).
- The build setting `ASSETCATALOG_COMPILER_ACCENT_COLOR_NAME` is the wrong key, so the tint is system blue (`project.pbxproj:397`).
- App Store: the app icon is SVG only (~30 MB `Assets.car`, alpha risk); convert it to PNG. The `ITSAppUsesNonExemptEncryption` key is missing.
- Hosted reset tests write the real reset-journal marker. An aborted run on a device could wipe that device's vault on the next launch.
