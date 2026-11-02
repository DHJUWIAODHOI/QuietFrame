# QuietFrame performance audit (Phase One)

| | |
|---|---|
| Date | 2026-11-02 |
| Branch / commit | `perf-rewrite` at `1c8d5d0` |
| Scope | All 82 Swift files under `QuietFrame/`, the 28 files under `QuietFrameTests/`, the UI test, the CI workflow and the Xcode project settings |
| Inputs | Six area audits (gallery and thumbnails; viewer and video; storage, crypto and security; persistence and maintenance services; import, export and PhotoKit; app shell and lifecycle). Each was re-checked by an independent verification pass. A completeness review confirmed that every Swift file was read by at least one auditor. |
| Purpose | Input for Phase 0 (baseline) and the rebuild phases in section 6 |

**Status note (read first).** Every code citation refers to `1c8d5d0`, which was the head of `perf-rewrite` when the area audits ran. Every file read for this report predates the changes below. While the report was being written, two commits landed on `perf-rewrite`:

- `96ba12b` "Add performance benchmarks and an optimized serial CI step for them". It adds 5 classes with 21 tests in `QuietFrameTests/Benchmarks/` (`CryptoBenchmarks`, `ThumbnailBenchmarks`, `LibraryBenchmarks`, `ViewerBenchmarks`, `ImportBenchmarks`) and a serial `-O` benchmark step in the `build` job that writes a summary table.
- `6d83bea`, which fixes one of those benchmarks.

Both touch only tests and CI. The working tree also holds uncommitted changes that this audit did not read: edits to `ThumbnailService`, `MediaThumbnailView`, `GalleryGridView`, `GalleryViewModel`, `TrashScreen`, `MediaViewer`, `ViewerFilmstrip`, `ViewerZoomTransition` and `AlbumsScreen` (a thumbnail-pipeline rewrite in progress), plus new tests.

Consequences for the plan:

1. Take the baseline run (7.5) on `6d83bea`, or on another commit that changes only tests and CI, before any of the thumbnail changes are committed. Otherwise P01, P02, P16 and P30 have no "before" number.
2. Reconcile section 7 with the existing classes (7.0) by extending them instead of duplicating them.
3. The new CI step runs on every push, but it is not yet the same-job A/B comparison that section 6.1 requires.

**Nothing in this report has been built, run or profiled.** The audit machine runs Windows and has no Xcode, no Instruments and no device. Every finding comes from reading the code and Apple's API semantics. Confidence labels:

- **certain**: follows directly from the code or from documented API behaviour;
- **likely**: very probable at the stated scale, but the size is an estimate;
- **speculative**: plausible, and must be measured before it drives a decision.

Millisecond and megabyte figures are order-of-magnitude estimates carried over from the verified audits. Device figures assume a Release build on a recent iPhone unless stated. Deterministic quantities (bytes per bitmap, call counts, rows fetched) are computed from the code. CI runs a Debug build on a shared simulator, so CI numbers will not match device numbers; only before/after comparisons on the same runner mean anything (section 6.1).

Scale used throughout: 100 / 1,000 / 10,000 media items; photos of 12 to 48 MP in HEIC or JPEG (4032×3024 decodes to 48.8 MB of RGBA, 8064×6048 to 195 MB); videos up to several hundred MB.

Rebuild constraint: UI, UX, features, behaviour, vault data, file formats, encryption and migrations stay exactly compatible. The app stays offline and private, and every CLAUDE.md security invariant holds.

**Contents**

1. Current architecture
2. Feature inventory (regression checklist)
3. Performance problems and evidence
4. Proposed architecture
5. Data compatibility risks
6. Rewrite and verification strategy
7. Benchmark plan

---

## 1. Current architecture

### 1.1 Layers and isolation

| Layer | Types | Isolation |
|---|---|---|
| Views | `RootView` / `AuthenticatedRootView`, gate screens, `MainTabView` (4 `NavigationStack`s), `GalleryBrowser` → `GalleryGridView` → `MediaThumbnailView`, `MediaViewer` (with `SecureMediaPage`, `ViewerChrome`, `ViewerFilmstrip`, `ViewerScrubber`, `ViewerDetailsPanel`, `ZoomablePhotoView`), `AlbumsScreen`, `TrashScreen`, `SettingsScreen` and its sheets, `ImportPreviewView`, `PhotoLibraryPicker`, `PrivacyShieldView` / `PrivacyShieldWindow` | Main actor |
| UI state and composition | `AppModel`, `AppDependencies`, `VaultLockCoordinator`, `GalleryViewModel`, `ImportViewModel`, `ViewerPhotoLoader`, `ViewerVideoPlayback`, `ThumbnailService` (NSCache: 500 items, 64 MiB) | `@MainActor`; all `@Observable` except `ThumbnailService` |
| Data services | `VaultRepository`, `AlbumService`, `TrashService`, `StorageReconciliationService`, `StorageAnalysisService` | `@MainActor`, all on `modelContainer.mainContext` (autosave on) |
| Actors | `AuthenticationService` (uses `KeychainService` and `PBKDF2`), `VaultSession`, `SecureFileStorageService`, `ChunkedEncryptionService`, `MediaImportService`, `MediaExportService`, `MediaMetadataService`, `ThumbnailGenerator`, `PhotoLibraryService`, `VaultOperationGate` | One instance of each, built once in `AppDependencies.init` |
| Storage | SwiftData `Application Support/default.store` (VaultSchemaV3; plaintext metadata protected by iOS); QFRAME01 files under `Application Support/QuietFrameVault/{media,thumbnails,trash,staging}`; Keychain service `com.quietframe.vault.security`; `Caches/QuietFrameTemporary`; `tmp/QuietFrameIncoming` | — |

Isolation facts behind the findings:

- **All SwiftData work runs on the main thread.** The `@MainActor` services pass non-Sendable closures to `VaultOperationGate.withLock`. In Swift 5 mode those closures inherit main-actor isolation, so the fetches and saves inside reconcile, purge, Trash operations and album delete run on main too.
- **All chunk crypto runs on one executor.** Every operation goes through the single `ChunkedEncryptionService` and interleaves with others only at the per-chunk `await session.validate(_:)` and `await progress(_:)` points. `SecureFileStorageService` releases its own executor while it waits on the encryption actor.
- **Image decoding is split.** Viewer photos are decoded off the main thread (ImageIO thumbnail, `kCGImageSourceShouldCacheImmediately`, at most 4096 px). Thumbnails for the gallery, album covers, the filmstrip and viewer placeholders are built with `UIImage(data:)` in a detached task. That call defers the JPEG decode to the first Core Animation commit, which runs on the main thread.
- **Nothing runs in parallel** in preparation, import or export; there are no task groups.
- **The tab view is rebuilt on every unlock.** `MainTabView` exists only in `.unlocked`. Every lock destroys it and clears the thumbnail cache.

### 1.2 Data flows

**Launch → unlock → first gallery content**

1. `RootView.task` calls `AppModel.bootstrapIfNeeded()` on main, with `LaunchView` visible throughout:
   - finish any pending reset journal (off main);
   - protect the store directory;
   - call `ModelContainer(for:migrationPlan:configurations:)` synchronously, running the lightweight V1→V2→V3 migration if needed;
   - protect the store, `-wal` and `-shm` files;
   - run `initializeAlbumPositions` (fetches all albums);
   - seed `AppSettings`;
   - run `AppDependencies.init`, which prepares 6 protected directories.
2. `AuthenticatedRootView.task` runs with the shield up. `VaultLockCoordinator.initializeIfNeeded()` runs these steps in order: clean temp and staging, read the biometric kind (LAContext), read the lockout date, read the authentication mode (Keychain). The result is one of:
   - `.locked` (passcode mode);
   - a silent unlock plus maintenance (no passcode);
   - onboarding;
   - recovery.

   The shield drops after the active-scene handling finishes.
3. Passcode unlock:
   - `AuthenticationService.unlock` (actor) makes 3 Keychain XPC calls, derives the key with PBKDF2-HMAC-SHA256 (210,000 iterations), checks the verifier in constant time, unwraps the master key with AES-GCM, and calls `session.unlock`.
   - `postUnlockMaintenance` then runs reconcile and purge, both under the gate with their bodies on main.
   - Only then does `state` become `.unlocked`.

   Face ID uses LAContext and the biometric Keychain item, then the same maintenance.
4. On `.unlocked`:
   - `MainTabView` inserts (0.32 s, after a 0.08 s delay) while the 0.42 s iris flourish plays.
   - `GalleryBrowserContent.task` calls `GalleryViewModel.loadInitial()`, a synchronous main-actor fetch of 81 rows.
   - Each visible tile requests its thumbnail.

**Thumbnail load**

1. `MediaThumbnailView.task(id: thumbnailIdentifier)` calls `ThumbnailService.image(for:)` on main. A cache hit returns at once, and an in-flight request for the same identifier is shared.
2. On a miss, an unstructured `Task` calls `SecureFileStorageService.decryptData(.thumbnails, max 16 MiB)`. That does a stat, then on the encryption actor: header read, HKDF, AES-GCM, and 3 session hops.
3. A detached task runs `UIImage(data:)`, which does no pixel decode.
4. Back on main, the image goes into NSCache with cost w×h×scale²×4, then into the tile's `@State`.
5. The JPEG is decoded on main at the first commit.

The work is not cancelled when the tile disappears. The viewer reads `cachedImage(for:)` synchronously.

**Viewer open and paging**

- A tap presents `MediaViewer(items: <the loaded gallery items>, ...)` as a `fullScreenCover`, with animations disabled and a clear background.
- The opening flight needs both `cachedImage(for:)` and the tile frame from `MediaTileFrames`. If either is missing it falls back to a fade.
- Every body evaluation scans `items` linearly several times and builds `Array(items.enumerated())`.
- A page change calls `onCurrentMediaChange`, which writes the presenter's `@State hiddenMediaID`. That re-renders the presenter and the hidden grid, and re-creates `MediaViewer`.
- Photos among [selected, next, previous] are decrypted in memory one at a time (up to 512 MiB), decoded off main to at most 4096 px, and stored in one observed dictionary.
- On dismiss the presenter calls `refreshLoadedItems()`.

**Video play**

Only the active page loads its video:

1. `temporaryDecryptedFile` does a stat, reads attributes, checks that important-usage capacity is at least the encrypted size + 32 MiB, runs a full sequential `decryptFile`, fsyncs, and applies protection.
2. The result is a `SecureTemporaryFileLease` feeding an `AVQueuePlayer` + `AVPlayerLooper`.
3. `ViewerVideoPlayback.attach` adds a 30 Hz time observer; scrubber frames come from a second `AVURLAsset`.

Leaving the ±1 window, `onDisappear` or a lock deletes the file, so re-activating the page decrypts it again.

**Import**

1. The picker runs on main and makes two synchronous PhotoKit queries per result to decide deletion eligibility.
2. `ImportViewModel.prepare` handles one item at a time: copy the provider file into `tmp/QuietFrameIncoming`, read metadata, make a 720-px JPEG preview. All candidates are published at the end.
3. The user reviews the candidates.
4. `MediaImportService.importMedia` holds the gate for the whole batch. Per item:
   - query free space;
   - `store(.media)`: 1 MiB chunks, SHA-256, AES-GCM, fsync, move, with a main-actor progress hop awaited after every chunk;
   - `containsFingerprint` (main);
   - write the thumbnail as a plaintext temp file and store it with a second `store`;
   - `insertImportedMedia` (main insert and save);
   - progress tick.

   Incoming files are deleted when the batch ends.

**Trash**

- **Move to Trash and Restore:** take the gate → fetch the whole VaultMedia table and filter by ID (main) → one actor call per file move → mutate → one save. If the save fails, the files are moved back.
- **Permanent delete and Empty Trash:** take the gate → whole-table fetch → delete the rows → save → delete 2 files per item.
- **The Trash tab:** its `.task` purges (through the gate) before it refreshes. After every Trash operation the screen clears the entire thumbnail cache.

**Reconcile and purge (after every unlock)**

1. Take the gate and fetch every VaultMedia (main).
2. Build 3 identifier sets.
3. Make 3 serial directory listings on the storage actor, creating an NSURL per entry.
4. Repair interrupted moves and delete unreferenced files.
5. Purge: fetch the settings and every trashed row, and filter expired items in Swift. If any have expired, fetch the whole table again and delete them.

### 1.3 Other structural facts

- **No performance tests existed at `1c8d5d0`** (zero `measure(` calls). The suite had 167 unit tests in 25 files, plus 1 UI test. Benchmarks were added afterwards; see the status note at the top.
- **CI** (`.github/workflows/build-ipa.yml`):
  - builds the Debug configuration (`SWIFT_OPTIMIZATION_LEVEL = -Onone`) for an iPhone 16 Pro simulator at `OS=latest` (iOS 18.x);
  - runs `QuietFrameTests`, which the scheme marks as parallelizable;
  - uploads logs and the `.xcresult` only when a run fails;
  - triggers on push to `main` and on `workflow_dispatch`;
  - prints the Xcode version but never selects one.
- **`VaultSchemaV3.models` lists the live `@Model` classes**, so any edit to a model changes the V3 checksum.
- **iOS 17 SwiftData has no `#Index`.** Only unique attributes are indexed, and very probably the album foreign key.
- **`GalleryViewModel` holds live `[VaultMedia]`.** Its fetches are synchronous inside `async` functions, so today its loading spinners and generation guards do nothing.

---

## 2. Feature inventory (regression checklist)

Every item must behave the same after every phase, unless section 6.4 lists an approved change. **Quirk** marks current behaviour that looks unintended: keep it, or change it only through 6.4. Quoted strings are verbatim.

### 2.1 Launch, bootstrap and privacy shield

- [ ] **System launch screen:** generated and empty (`INFOPLIST_KEY_UILaunchScreen_Generation = YES`), so it shows the system background (white in Light Mode) before SwiftUI starts. **Quirk.**
- [ ] **LaunchView:** opaque `vaultGradient`, a sealed `ApertureMark` (120), serif "QuietFrame".
  - One accessibility element, "QuietFrame is opening", id `launch`.
  - Shown during bootstrap, while the coordinator is `.loading`, and as the locked screen in no-passcode mode while the silent resume runs.
- [ ] **Bootstrap order:**
  1. Finish any pending reset journal before SwiftData opens: delete the 4 Keychain items, `QuietFrameVault`, `Caches/QuietFrameTemporary`, `tmp/QuietFrameIncoming` and every store-directory file whose name starts with the store filename, then remove the marker.
  2. Protect the store directory and exclude it from backup.
  3. Open `default.store` with `VaultSchemaV3` and `VaultMigrationPlan`.
  4. Protect `default.store`, `-wal` and `-shm`.
  5. Backfill album positions only when they are not unique (ordered by `createdAt`, then `uuidString`).
  6. Seed the `AppSettings` singleton.
  7. Build `AppDependencies`.
- [ ] **Bootstrap failure:** `VaultProblemView` "Vault unavailable" with `externaldrive.badge.exclamationmark`, the message "The local vault database could not be opened." and a "Try again" button that re-runs bootstrap. Id `migration-error`.
- [ ] **VaultProblemView layout:** 40-pt light brass symbol, serif title with the header trait, message, actions, readable width, page padding, night background.
- [ ] **Gate screen per state:**
  - `.loading` → LaunchView.
  - `.needsOnboarding` → Onboarding.
  - `.locked` → UnlockView in passcode mode, LaunchView in no-passcode mode.
  - `.unlocked` → MainTabView.
  - `.retryRequired` → "QuietFrame couldn't open" (`arrow.clockwise.circle`; the coordinator's message or "Try opening the vault again."; a "Try again" button that calls `retryOpeningVault`). Id `vault-retry-required`.
  - `.recoveryRequired` → "Encryption key unavailable" (`key.slash`; the message or "QuietFrame cannot safely open the existing vault."; a destructive "Erase unrecoverable vault" button that opens the RecoveryResetView sheet). Id `key-recovery-required`.
- [ ] **Transitions:**
  - Gate screens insert with no transition and leave with a 0.16 s ease-out fade (0.2 s with Reduce Motion).
  - The onboarding→locked hand-off (`isFinishingOnboarding`) has no transition.
  - MainTabView inserts with opacity plus scale 0.97 on `timingCurve(0.23,1,0.32,1)` over 0.32 s, after a 0.08 s delay. With Reduce Motion it is a 0.2 s ease-out fade.
  - MainTabView is removed instantly (`.identity`). Locking is instant and vault content never fades out over a locked state.
- [ ] **Privacy shield:** shown when the scene is not active or the screen is captured. It has two layers:
  - a SwiftUI overlay at zIndex 100;
  - a UIKit `UIWindow` at level `.alert + 1`, shown synchronously on `UIScene.willDeactivate`, hidden on `didActivate`, and kept visible while the screen is captured.

  It shows `vaultGradient`, a sealed `ApertureMark` (150) and "QuietFrame". While the screen is captured it reads "Sensitive content hidden" and "Stop screen recording or mirroring to view your vault.". It is forced dark and is one modal element: "QuietFrame is locked from view" or "Sensitive content hidden during screen capture", id `privacy-shield`. Content under it takes no hits and is hidden from accessibility. The shield starts visible at launch and drops only after active handling.
- [ ] **Screen capture:** capture start locks immediately. Capture end, with the scene active, re-runs active handling and lowers the shield.

### 2.2 Onboarding

- [ ] **Welcome:**
  - An open `ApertureMark`: 176, or 120 at accessibility sizes or compact height.
  - Serif "Your moments, / held quietly." (`quietScreenTitle`) and a privacy blurb.
  - Three points: `lock` "Encrypted at rest", `icloud.slash` "Excluded from iCloud backup", `checkmark.rectangle` "Photos access only when you choose".
- [ ] **Buttons:**
  - "Use a passcode" (`aperturePrimary`, id `start-setup`).
  - "Continue without passcode" (`apertureSecondary`, id `skip-passcode`). It opens the dialog "Continue without an app passcode?" with a message, "Continue without passcode" (calls `createWithoutPasscode`) and a cancel-role "Use a passcode" (goes to the create step).
- [ ] **Steps:** "Create your passcode", then after 6 digits "Confirm your passcode", which calls `createPasscode`.
  - A mismatch shows "The passcodes do not match.".
  - A failure clears only the confirmation; there is no way back to change the first entry.
  - Errors appear in a `quietCard` error row labelled "Error: <message>".
  - Step changes animate with `.snappy` unless Reduce Motion is on. Id `onboarding`.
- [ ] **`createPasscode`:**
  - Requires exactly 6 characters, each '0'-'9'; otherwise "Enter the correct six-digit passcode.".
  - Refuses unless the mode is not configured ("Vault authentication is already configured.").
  - Generates a 32-byte `SecRandomCopyBytes` master key and stores the `passcode-envelope-v1` envelope.
  - Clears the attempt state and unlocks.
  - Passes through `.locked`, then maintenance, then `.unlocked`. There is no iris flourish on the first open.
- [ ] **`createWithoutPasscode`:** stores the raw key in `unwrapped-master-key-v1` and sets mode `.none`, then `.locked`, maintenance, `.unlocked`.

### 2.3 Unlock screen, biometrics and lockout

- [ ] **Layout:** `AuthenticationLayout` (scrollable, readable width, compact below 700 pt of height), serif "QuietFrame", "Enter your passcode to continue". Id `unlock-screen`.
- [ ] **Passcode field:** `SixDigitPasscodeField` with an iris of 120 (compact), 128 (accessibility sizes) or 176. It is disabled while working or locked out, and the sixth digit calls `unlock`.
- [ ] **Wrong code (any failure):** ember blades and a shake (none with Reduce Motion). The passcode clears after 240 ms and the tint after another 260 ms.
- [ ] **Status cards:**
  - The lockout card (clock icon, monospaced "Try again in N second(s)", updated each second by a `TimelineView`) takes precedence over the error card ("Error: <message>").
  - Message changes animate with `.snappy` unless Reduce Motion is on.
  - A lockout task sleeps until the lockout expires, then clears it and any message containing "Too many attempts" (string match).
- [ ] **Biometric button:** "Unlock with Face ID" or "Unlock with Touch ID" (secondary pill, `faceid` / `touchid`, id `biometric-unlock`) when biometrics are enabled and available. The prompt also appears automatically once per UnlockView appearance.
- [ ] **Forgot passcode:** "Forgot passcode?" opens the dialog "Forgot your passcode?" with a destructive "Erase vault and start over" (opens the RecoveryResetView sheet), Cancel and a message.
- [ ] **Footer:** lock icon and "Media remains encrypted on this device".
- [ ] **Unlock iris flourish:**
  - The field publishes a `PasscodeIrisSnapshot` (global frame, closure, filled blades, size).
  - It plays on `.unlocked` only when this is not the first open after onboarding, Reduce Motion is off, and a snapshot exists.
  - It sits at zIndex 50, ignores the safe area, takes no hits and is hidden from accessibility.
  - Over 0.42 s on `timingCurve(0.23,1,0.32,1)`: closure → 0 (starting sealed if 6 blades were filled), scale 1 → 1.4, rotation 0 → 35°, opacity 1 → 0. It then removes itself by id.
  - UnlockView hides its own iris (no animation) and fades out over 0.16 s.
  - After a Face ID unlock it plays from the open, empty iris. Any non-unlocked state cancels it.
- [ ] **Passcode unlock semantics:**
  1. Check the format, then the lockout.
  2. Read the envelope. Missing → `missingEncryptionKey`: "The vault encryption key is unavailable. Your media was not changed." Undecodable → `keychainFailure`: "Secure credentials could not be accessed."
  3. PBKDF2, then the constant-time verifier, then the AES-GCM unwrap, then the session unlock.
  4. On success the attempt state is deleted.
- [ ] **Escalating lockout:**
  - Failures in unlock, change passcode, remove passcode and the normal-reset check increment `failedCount` in the Keychain.
  - Delays are [0,0,0,1,2,5,15,30,60,300,900,3600] s: the 4th failure gives 1 s, the 12th and later give 1 h. The count never decays and uses the wall clock.
  - Message: "Too many attempts. Try again <relative>.".
- [ ] **Biometric unlock:**
  - Uses `LAContext` `.deviceOwnerAuthenticationWithBiometrics` with cancel title "Use Passcode" and reason "Unlock your private QuietFrame library".
  - Reads `biometric-master-key-v1` with `kSecUseAuthenticationContext`, so there is no second prompt.
  - A missing item or `errSecAuthFailed` means `biometricsChanged`: lock, turn the setting off (best-effort save), delete the item, and show "Biometric data changed. Unlock with your passcode, then enable biometrics again in Settings."
  - LA errors map as follows:
    - `notAvailable`, `notEnrolled`, `passcodeNotSet` → "Biometric authentication is not available."
    - `biometryLockout` → `temporarilyLocked(now + 30 s)`. This also disables the passcode keypad for 30 s. **Quirk.**
    - Anything else, including cancel and fallback → "Authentication was not successful. Please try again."
  - Success clears the attempt state. Optic ID counts as no biometrics.
- [ ] **`perform` failure handling:** ignored while already working. On failure the session locks and the VaultError text is shown. No-passcode open failures go to `.retryRequired`, or to `.recoveryRequired` for `missingEncryptionKey`.

### 2.4 Six-digit passcode field (component)

- [ ] **Iris:**
  - Closes one blade per digit (closure = count / 6).
  - Blades animate over 0.16 s on `timingCurve(0.23,1,0.32,1)`, or 0.26 s while showing an error; no animation with Reduce Motion.
  - The ember error tint fades in over 0.12 s and lasts until the next keystroke.
  - Shake keyframes: x = −10, 8, −5, 3, 0 over 0.04 / 0.045 / 0.05 / 0.06 / 0.125 s; none with Reduce Motion.
  - Optional `hidesIris`.
- [ ] **Keypad:**
  - A `Grid` with 28 × 12 spacing: 1-9, a blank cell, 0, and delete (`delete.left`, disabled when empty, "Delete last digit").
  - Keys are 68 pt, scaled with `title2` and capped at 84, drawn as dusk circles with 28-pt monospaced digits.
  - The disabled keypad drops to 0.45 opacity.
- [ ] **Input rules:**
  - Digits only, at most 6. `onComplete` fires when the count goes from below 6 to 6.
  - Hardware-keyboard digits and delete work through `onKeyPress`. The field is focusable unless disabled, requests focus on appear, and has its focus effect disabled.
  - A light impact haptic fires on every count change, including programmatic clears.
- [ ] **Accessibility:** the iris is one element labelled with the field label, value "N of 6 digits entered". The keypad container is "Passcode keypad"; keys are labelled with their digit.

### 2.5 Lock state machine and auto-lock

- [ ] **`initializeIfNeeded` (runs once):** clean temp and staging, then read the biometric kind, the lockout date and the mode.
  - Passcode → `.locked`.
  - None → silent unlock, maintenance, `.unlocked`.
  - Not configured → onboarding. If VaultMedia rows exist, recovery instead, with "The vault encryption key is unavailable. Your media was not changed.".
- [ ] **`lock()`:**
  1. Cancel any delayed lock.
  2. Set `state = .locked` first, unless the state is `.needsOnboarding`, `.retryRequired` or `.recoveryRequired`.
  3. Lock the session; the generation bump revokes in-flight crypto at the next chunk.
  4. Cancel imports (bump the import generation, remove incoming files).
  5. Clean temp and staging, clear the message, refresh the lockout date.

  RootView clears the thumbnail cache whenever the state leaves `.unlocked`.
- [ ] **Auto-Lock:** values Immediately (0), 30 s, 60 s, 300 s, stored as raw seconds.
  - `.inactive` stamps `backgroundedAt` once, only when unlocked and not working.
  - `.background` locks at once for 0, otherwise schedules a `Task.sleep` lock.
  - `.active` cancels the delayed lock. A no-passcode vault resumes silently (unlock plus maintenance). A passcode vault locks if the elapsed time is at least the delay. The stamp is then cleared.
- [ ] **Lifecycle forwarding:** RootView maps `scenePhase` to events through one cancellable `lifecycleTask`. Any non-active phase sets `sceneIsObscured` immediately.
- [ ] **Known issues** (keep each, or fix it through 6.4):
  - With Immediately, any inactive→active transition locks, including the app's own Face ID enable, Photos permission, delete confirmation and Save to Photos prompts.
  - Backgrounding during an in-flight unlock leaves the vault unlocked past the auto-lock grace period.
  - A reconcile or purge failure blocks unlock and shows an authentication-style error. After a correct passcode, UnlockView still plays the wrong-code shake and clears the entry.
- [ ] **Other entry points:** `retryOpeningVault` works only from `.retryRequired`; `clearMessage`; `clearExpiredLockoutIfNeeded`.

### 2.6 Main tabs

- [ ] **Tab bar:** a `TabView` with Vault (`square.grid.2x2`), Albums (`rectangle.stack`), Trash (`trash`) and Settings (`gearshape`), each in its own `NavigationStack`. Brass tint, night background, id `main-tabs`.
- [ ] **Lifetime:** exists only while unlocked and is rebuilt on every unlock, so Vault is selected, every stack is at its root and scroll positions reset. Visited tabs stay alive until the next lock.

### 2.7 Galleries (Vault, collections, albums)

**Screens and grid**

- [ ] **Vault tab:** `GalleryBrowser` titled "Vault" (large serif title) over `GalleryQuery(collection: .allMedia)`, i.e. non-trashed items. It is the only gallery with import: a toolbar "Import" button (`plus`, id `import-media`) and the empty-state "Choose media" button (id `choose-media`).
- [ ] **Collections** (pushed from the Albums tab):
  - All Media.
  - Recently Added: `importedAt >= now − 30 days` using `Calendar.current`, recomputed on every fetch.
  - Favorites: the Favorites filter behaves like All here.

  No import. Empty copy: "No media here" / "Items matching this collection will appear here."
- [ ] **Album galleries:** `GalleryQuery(collection: nil, albumID:)`, titled with the album name.
  - On first load the date direction comes from `AppSettings.albumMediaDateSortDirection`, one global setting shared by all albums.
  - The "Sort order" picker (Newest First / Oldest First) appears only for Date Imported and Date Created. Choosing a value saves AppSettings (rollback and alert on failure) and reloads from page 1.
  - The selection bar adds "Cover" when exactly one item is selected.
- [ ] **Grid layout:** `ScrollView` + `LazyVGrid` with one adaptive `GridItem`.
  - Column width: minimum = thumbnail width × 0.85, maximum = × 1.45. Widths: Compact 90, Comfortable 120, Large 165; Trash falls back to 120.
  - At accessibility sizes: minimum 280, maximum 560 (one column on iPhone).
  - Spacing 6, top alignment, 24 pt horizontal and 8 pt vertical padding, night background.
  - On iPhone 16 Pro, Comfortable gives 3 columns of about 114 pt.
- [ ] **Tile:** square (it may grow taller at large text sizes), 10-pt continuous corners, thumbnail `scaledToFill` behind.
  - Placeholder: dusk fill with a photo or video symbol (`title3`, mist), shown while loading or when the thumbnail is missing or failed.
  - Bottom badges (inset 6, caption medium, moon):
    - a Trash date capsule (`trash.fill` + abbreviated date);
    - a favourite `heart.fill` in a night 78% circle;
    - a video duration of `m:ss` or `h:mm:ss` (monospaced, one line, minimum scale 0.7).
  - `ViewThatFits` puts the heart left and the duration right, or stacks them.
  - Selection badge, top right: unselected is an empty ring (night 55% fill, 1.5 pt moon stroke); selected is a brass circle with a night bold checkmark. A selected tile also gets a 3 pt brass inner stroke.
  - Badge size is `@ScaledMetric` 24, relative to caption.
- [ ] **Tile gestures:**
  - Tap opens the viewer, or toggles selection while selecting. Deselecting the last item leaves selection mode.
  - A long press of at least 0.35 s enters selection with that item.
  - Context menu, with the preview clipped to the tile shape:
    - "Favorite" / "Remove favorite" (`heart` / `heart.slash`). The badge updates through model observation; the list is not refreshed.
    - "Select" (`checkmark.circle`).
  - Plain button press feedback.
  - The same gestures work in Trash, so trashed items can be favourited. **Quirk.**
  - How the long press and the context menu interact must be checked on a device and reproduced exactly.
- [ ] **Tile accessibility:** one element.
  - Label: `accessibilitySummary`, i.e. the display name (or "Private Photo" / "Private Video"), "Photo" / "Video", "favorite", the abbreviated import date, "album <name>", and `m:ss` for videos. In Trash, ", deleted <date>" is appended.
  - Value: "Selected" / "Not selected", only in selection mode.
  - Custom actions: "Favorite" / "Remove favorite" and "Select".
- [ ] **Grid animation:** changes of `items.count` animate with `.easeInOut(duration: 0.18)` (none with Reduce Motion). This covers new pages, the reflow after Move or Trash, and switches between the empty, skeleton and grid states.
- [ ] **Tile frames and viewport:**
  - Each visible tile reports its global frame into `MediaTileFrames`: set on appear and on change, removed on disappear. Nothing re-renders as a result.
  - The scroll view reports its unobscured viewport: its global frame minus the top and bottom safe-area insets.
  - The viewer opens from the tile only if the thumbnail is cached.
  - On close it returns to the tile only if the tile lies wholly inside the viewport (±1 pt). Otherwise the image slides away and fades. With Reduce Motion it only fades.
- [ ] **Hidden source tile:** the tile of the item shown in the viewer has opacity 0, set on viewer appear and on every page change. It reappears when the closing flight lands, or at the start of a fade close. After Trash, Restore or Delete it is not revealed; the presenter clears it after its `onDismiss` refresh.
- [ ] **Viewer presentation:** a tap presents `MediaViewer` as a `fullScreenCover` without the system animation (`Transaction.disablesAnimations`) and with a clear background. It passes the loaded items in grid order, `MediaTileFrames` and `onCurrentMediaChange`. On dismissal the grid refreshes in place.

**Loading, paging and refresh**

- [ ] **Paging:** the first 80 items load on first appearance; the next 80 load when the last loaded tile appears and `hasMore` is true (a limit+1 probe). There is a "Loading more media" spinner (mist), but it never shows today because fetches are synchronous.
- [ ] **Refresh in place** (keeps scroll depth):
  - Triggers: viewer dismissal, re-appearance of the screen (for example switching back to the tab), import-preview dismissal, Move, Move to Trash, and Trash Restore / Delete / Empty.
  - Each re-fetches `max(loaded, 80)` items from offset 0. Items that left the query drop out and new ones shift in.
  - The selection keeps only the surviving IDs, and the tile that becomes last re-arms paging.
- [ ] **Start over:** pull-to-refresh, "Try again", and changes of filter, sort, sort order or search all call `loadInitial`. That goes back to page 1, clears the selected IDs and the error, but leaves `isSelecting` unchanged, so "0 selected" can remain. **Quirk.**
- [ ] **Empty results:** when results become empty, the empty view replaces the `ScrollView`. When results come back, a new `ScrollView` starts at the top.

**Filter, sort and search**

- [ ] **Filter chips:** a top safe-area inset under the search field.
  - Shown when items exist, or the filter is not All, or the search text is non-empty. Not shown in Trash.
  - Chips: All / Photos / Videos / Favorites. The selected chip has a brass fill, night semibold text and the `.isSelected` trait; the others are dusk.
  - Minimum height 44; opacity 0.78 when pressed, 0.45 when disabled.
  - `ViewThatFits` falls back to a "Filter: <name>" menu.
  - Disabled while selecting. The container is labelled "Filter". Tapping the current chip does nothing.
- [ ] **"Filter and sort" menu** (`line.3.horizontal.decrease.circle`): a Filter picker, a divider, a Sort picker (Date Imported, Date Created, Name, Size, Type), and the album-only Sort order. While selecting it is replaced by "Cancel". Trash has the same menu without dividers.
- [ ] **Sort semantics:**
  - Date Imported: `importedAt` (in the chosen direction), then `storageIdentifier` ascending.
  - Date Created: `originalCreationDate` (direction; missing dates last for newest-first, first for oldest-first), then `importedAt` (direction), then `storageIdentifier`.
  - Name: `originalFilename` ascending, then `storageIdentifier`.
  - Size: `byteCount` descending, then `storageIdentifier`.
  - Type: photo before video, then `importedAt` descending, then `storageIdentifier`.

  The direction applies only to the two date sorts. Vault, collections and Trash always sort newest first. String keys use Foundation's default `localizedStandard` comparator.
- [ ] **Filter semantics:** All, Photos (`'photo'`), Videos (`'video'`) and Favorites (`isFavorite`) apply within the scope:
  - non-trashed items (Vault, collections);
  - the album (`album?.id`);
  - the Recently Added cutoff;
  - the Favorites collection;
  - trashed items only (Trash).
- [ ] **Search:** `.searchable` with the prompt "Filename, album, date, or tag" ("Search Trash" in Trash).
  - Text input is debounced 250 ms; filter and sort changes apply immediately. The text is trimmed.
  - An item matches when any of these holds, using `localizedCaseInsensitiveContains` (case-insensitive, diacritic-sensitive):
    - the filename, the album name or any tag contains the text;
    - the `.medium`/`.none` `DateFormatter` string of `importedAt` or `originalCreationDate` (current locale and time zone) contains the text;
    - the text equals the import year exactly.
  - Scope and filter still apply, results keep the current sort, and pages hold 80 items.
  - Album-name search never finds trashed items, because the album is cleared on trash.

**Selection mode and bulk actions**

- [ ] **Entering:** "Select" (in Trash, a `checkmark.circle` icon, disabled when empty), a long press, the context menu, or the VoiceOver "Select" action.
- [ ] **While selecting:**
  - The toolbar shows "<n> selected" (headline, one line, Dynamic Type capped at xxxLarge) and "Cancel". In Trash, Cancel is leading and the count sits in the bar.
  - The bottom bar is dusk, with a 28-pt continuous radius and a maximum width of 560. `ViewThatFits` shows one row, or the count plus a horizontally scrolling row.
  - Actions: Favorite, Move, Export, Trash, and Cover (albums only). All are disabled with 0 selected.
  - The selection persists after Favorite, Share and Save, and ends after Move, Trash and Cover.
- [ ] **Bulk Favorite:**
  - Only sets favourite; there is no bulk unfavourite.
  - One save per item; a failure shows "Vault changes could not be saved.". Partial success is possible. **Quirk.**
- [ ] **Move:**
  - Opens the `AlbumDestinationPicker` "Move to album" sheet: medium/large detents, dusk background, 28 pt radius, drag indicator.
  - "No album" is disabled in the Vault and collections, because `currentAlbumID` is nil there. **Quirk.**
  - Albums are listed by position; the current one is checked and disabled.
  - Moving ends the selection and refreshes in place; errors show an alert.
  - All or nothing: any trashed or missing ID gives `persistenceFailure`.
- [ ] **Export menu** "Export" (hint "Share or save to Photos"):
  - Share prepares decrypted leases, then shows the system share sheet. The lease is cleaned up on completion or dismissal.
  - Save to Photos confirms with "Saved N item(s) to Photos.".
  - The menu is disabled while exporting; errors show an alert.
- [ ] **Move to Trash:** the dialog "Move selected media to Trash?" with "Items remain encrypted and can be restored until the Trash retention period expires.", a destructive "Move to Trash" and Cancel. Afterwards the selection ends and the grid refreshes.
- [ ] **Cover:** in album galleries with exactly one item selected, "Cover" (photo icon, hint "Sets the selected item as the album cover") sets `coverMediaID` and ends the selection.

**States and messages**

- [ ] **Vault empty state:** `EmptyVaultView`:
  - a closed, unfilled `ApertureIris` (88, hidden from accessibility);
  - "Your vault is ready" and "Import photos and videos to protect them on this device." (or the error message);
  - an `aperturePrimary` "Choose media" button (+).

  It is also shown when a Vault filter or search has no results, with the chips still visible. **Quirk.**
- [ ] **Other empty states:**
  - Other galleries: `QuietIntroduction` (`photo.on.rectangle.angled`) with the gallery's copy, plus "Try again" when there is an error.
  - Trash: "Trash is empty" / "Deleted media remains encrypted here until it expires."
  - All scroll and are centred vertically.
  - Loading with no items shows a skeleton of 18 dusk tiles and a "Loading vault" spinner.
- [ ] **Messages:** a "QuietFrame" alert with a single OK shows the action message or the view-model error; OK clears both. Trash has its own `userMessage` alert.

### 2.8 Viewer

**Open, close and hidden tile**

- [ ] **Opening flight:**
  - Conditions: Reduce Motion off, a known tile frame, and the thumbnail in the cache.
  - The cached thumbnail flies from the tile rect (radius 10) to the aspect-fit rect (radius 0) over 0.36 s on the drawer curve `(0.32,0.72,0,1)`.
  - The backdrop fades in over 0.24 s `(0.23,1,0.32,1)`, and the chrome fades in for 0.16 s after a 0.12 s delay. The pager stays hidden until the flight lands.
  - Otherwise the viewer fades in over 0.2 s. A fallback timer (flight duration + 0.3 s) finishes the transition if the completion never arrives.
- [ ] **Closing:**
  - Triggered by the close button, the "Close Viewer" accessibility action or a dismiss drag. If the opening flight is still running, the close waits for it to land while the chrome fades.
  - The image flies back when Reduce Motion is off, the photo is unzoomed and an image exists (the decoded photo, else the cached thumbnail; a failed photo has none). It flies from its current dragged or raised rect:
    - to the tile (0.3 s ease-out, radius 0 → 10) if the tile lies wholly inside the unobscured viewport;
    - otherwise it slides 80 pt down while fading (0.25 s).
  - During that close, the backdrop fades, the pager hides and details close instantly.
  - Every other case is a 0.2 s fade. The final dismiss is unanimated.
- [ ] **Hidden-tile contract:** see 2.7.

**Paging, photos and zoom**

- [ ] **Paging:**
  - `TabView(.page)` with no index dots, its selection bound to the media UUID, over the loaded items in gallery order. It cannot page past the loaded pages (README limitation 10).
  - A page change resets zoom, shows the chrome, closes details without animation, pauses playback and reports the current media.
  - Pages can also change from the filmstrip and from the VoiceOver "Media position" element.
- [ ] **Photo window:**
  - Photos among [selected, next, previous] are decrypted in memory (≤ 512 MiB encrypted) and decoded off main to ≤ 4096 px with EXIF orientation applied, one at a time in that order.
  - The selected photo preempts a loading neighbour, but a cancelled load keeps its slot until it finishes.
  - Photos leaving the window are released, and everything is released on disappear.
  - While loading, the page shows the cached thumbnail with a small spinner ("Decrypting photo"), or a plain spinner if no thumbnail is cached.
  - On failure it shows `ContentUnavailableView` "Photo unavailable" (`photo.badge.exclamationmark`) with the VaultError text. Undecodable data maps to `corruptedFile`. A size overflow shows the storage message. **Quirk.**
  - Failures stay sticky while the photo is in the window.
  - Inactive pages draw `Image(...).scaledToFit()`.
- [ ] **Zoom:**
  - The active page uses `ZoomablePhotoView` (`UIScrollView` + `UIImageView`), 1× to 6× with bounce, aspect-fit and centred with content insets, pannable to every edge when zoomed.
  - Layout passes while zoomed keep the pan; size changes made while zoomed apply once zoom settles at the minimum.
  - Double-tap zooms to 3× around the tap point, or back to 1× (animated unless Reduce Motion).
  - A zoomed photo blocks the lift and the details raise, and closes with a fade.
  - The single tap and the double-tap recogniser are not exclusive, so a double-tap may toggle the chrome twice. Verify on a device and keep the behaviour.

**Gestures, chrome and details**

- [ ] **Chrome toggle:** a single tap toggles the chrome (show 0.26 s, hide 0.18 s ease-out; instant with Reduce Motion). With details open, the tap closes details instead. The status bar and home indicator hide with the chrome.
- [ ] **Lift (dismiss drag and swipe up for details):** a simultaneous `DragGesture` (minimum 24 pt, global coordinates).
  - It starts only when the drag is mainly vertical and the viewer is not zoomed, not working, not dismissing, not in a flight, not under a modal, and details are closed.
  - The media follows the finger, with upward drags damped ×0.25.
  - Scale is `1 − 0.35 × progress` (no scaling with Reduce Motion). Backdrop opacity is `1 − min(t / (0.6 h), 0.85)`, a floor of 0.15.
  - The chrome fades out over 0.1 s on a downward drag. The active photo drops its opaque background (`isLifted`).
  - Release:
    - past 120 pt, or past 12 pt at more than 400 pt/s → close;
    - above −60 pt, or above −12 pt at faster than −500 pt/s → open details;
    - otherwise spring back over 0.26 s with no bounce, and the chrome returns over 0.16 s.
  - A cancelled drag settles through the `GestureState` reset.
- [ ] **Details panel:** opened by the info button or a swipe up.
  - It rises with opacity plus a 28 pt offset (opacity only with Reduce Motion): opens in 0.3 s, closes in 0.2 s.
  - The media rises so that it rests on the panel top, at `min(max(0.47 h, 44 + 120), h)`, unless zoomed. A gradient fades the media into the panel.
  - A tap or a swipe down on the media closes it (more than 40 pt, or more than 12 pt at more than 400 pt/s).
  - While it is open, the pager takes no hits and is hidden from accessibility; the bottom controls fade out in 0.16 s and back in 0.28 s; the info glyph turns brass.
  - Rows:
    - Taken (`viewerLongDate`);
    - Imported (`.long` / `.shortened`);
    - Album or "No album";
    - Dimensions "W × H", oriented using the decoded size;
    - Size (`ByteCountFormatter`, `.file`);
    - Duration (videos only);
    - Original name;
    - Deleted (Trash only);
    - Storage "Encrypted on this <device model>".
  - VoiceOver focus moves to the heading after 0.3 s. The "Close details" action and escape close it and return focus to the info button after 0.25 s. Rows stack through `ViewThatFits` at accessibility sizes.
- [ ] **Top bar:**
  - A chevron close button (20 pt medium).
  - A centred caption from the capture date, falling back to the import date: a serif headline such as "12 March 2026" over "Thursday at 18:42" in caption style with monospaced digits, locale- and time-zone-aware.
    - It allows 2 lines at accessibility sizes in regular height.
    - It has the header trait and is one combined element.
  - The info toggle, with value Shown / Hidden.
  - Both buttons support the large content viewer.
  - The top scrim (night 0.88 → 0.8 → 0) extends 62 pt below the bar (28 pt in compact height).
- [ ] **Bottom controls:**
  - A bottom scrim (safe area + 196 pt, 150 pt in compact height) that fades with details.
  - Then the scrubber for videos, or the filmstrip for photos when there is more than one item.
  - Then the action row.
  - Maximum width 560, centred. 8 pt extra bottom padding when there is no bottom safe area. Forced dark, ink tint.
- [ ] **Filmstrip:**
  - Shows the selected item plus enough neighbours to reach both edges (7 per side at 390 pt, so 15 tiles).
  - The selected tile is 52×40 pt, centred, with a 2 pt brass bar. Other tiles are 28×40 pt at 70% opacity, 3 pt apart, with 4 pt corners and 32 pt faded edges.
  - Tiles under the fade are not tappable; a tap selects the item.
  - The strip slides over 0.24 s on a selection change (none with Reduce Motion).
  - Thumbnails come from the cache first, then from an async load. The strip is hidden from VoiceOver.
- [ ] **VoiceOver "Media position":** an invisible adjustable element with the value "i of n"; increment and decrement change the page. It sits behind the strip or scrubber and stays in place when one replaces the other.
- [ ] **Action row:**
  - Vault item:
    - Favorite (`heart`, or brass `heart.fill`; label Favorite / Unfavorite);
    - an Export menu (Share, Save to Photos; 45% opacity while working);
    - Play/Pause in the middle for videos (28 pt; disabled when the video is unavailable; `startsMediaSession` trait while paused);
    - Move (`folder`);
    - Move to Trash (ember).
  - Trashed item: Restore, Export, Delete permanently (`trash.slash`, ember), and Play for videos.
  - Glyph buttons have 44 pt hit areas, 0.55 opacity when pressed and 0.45 when disabled, and large content viewer labels.

**Actions**

- [ ] **Favorite:** toggles through `repository.setFavorite`, which also bumps `album.modifiedAt`. A failure shows the "QuietFrame" alert with the persistence message.
- [ ] **Move:**
  - An `AlbumDestinationPicker` sheet with albums in position order (from `@Query`): medium/large detents, elevated background, 28 pt radius, drag indicator.
  - The current album is disabled with a checkmark. "No album" is disabled when the item has no album.
  - There is no "New album" option in the viewer. Errors show an alert.
- [ ] **Share:** sets `isWorking`, decrypts the item to a protected temp file through `MediaExportService` (under the gate), and presents `ShareSheet`. The lease is cleaned up on completion, dismissal or dismantle. Errors fall back to `exportFailed`.
- [ ] **Save to Photos:** requests add-only authorization, decrypts, adds through PhotoKit with the original creation date, then shows "Saved to Photos.".
- [ ] **Move to Trash:** "Move this item to Trash?" / "The encrypted item can be restored until it expires." → `moveToTrash` → fade-out that does not reveal the tile.
- [ ] **Restore** (Trash viewer): no confirmation → fade-out.
- [ ] **Delete permanently:** "Permanently delete this item?" / "This removes the encrypted file from this device and cannot be undone." → `permanentlyDelete` → clears the whole thumbnail cache → fade-out.
- [ ] **Action errors:** each shows an alert and re-enables the actions. The action row can switch between the vault and trash layouts during the 0.2 s fade. **Quirk.**
- [ ] **Alerts and modal guard:** errors use the "QuietFrame" title with VaultError text (each action has its own fallback). The lift is disabled while any sheet, dialog or alert is presented.

**Video**

- [ ] **Video page:**
  - Shows the cached thumbnail as a poster.
  - Only the selected page decrypts its whole video to a protected temp file (spinner "Preparing encrypted video").
  - Playback: `AVQueuePlayer` + `AVPlayerLooper` (gapless loop) in a control-less, gesture-less `AVPlayerLayer` (aspect fit).
  - Neighbour pages keep an existing player paused but never start one.
  - Leaving the window or disappearing cleans up: detach, stop looping, remove items, delete the file.
  - An inactive or background scene pauses playback.
  - On failure the page shows "Video unavailable" (`video.slash`) with the message, and Play is disabled.
  - Returning to a video that still has its player resumes from the paused position; otherwise it decrypts again and starts from 0. On a device the player is probably torn down on swipe; measured by B7.
- [ ] **Playback transport:**
  - One shared `ViewerVideoPlayback`. A play intent recorded before a player is attached applies on attach.
  - Play and pause come from the action row or the magic tap.
  - The chrome hides when playback starts and returns when it stops, except while scrubbing, with details open, or with VoiceOver or Switch Control running.
  - An interruption, route change or failure ends the play intent; a failure also marks the item unavailable.
  - There is no `AVAudioSession` configuration.
- [ ] **Scrubber:**
  - Elapsed and remaining times (remaining prefixed with a minus sign and rounded), caption style, monospaced.
  - A frame strip of `max(6, width / 28.5)` frames decoded in memory only by `AVAssetImageGenerator` (120 px, ±0.5 s tolerance), with the cached thumbnail in each slot until frames arrive. Strip 40 pt, 4 pt overhang, radius 6.
  - A brass 2 pt playhead with a dark outline.
  - A drag from touch-down (minimum distance 0) scrubs with exact seeks. It pauses the player but keeps the play intent, and resumes on release or cancel.
  - VoiceOver element "Playback position", value "x of y", adjustable by ±5 s.

**Accessibility, layout and release**

- [ ] **Accessibility:**
  - Id `media-viewer`; named action "Close Viewer"; magic tap toggles playback.
  - Page images are labelled with `accessibilitySummary`. The video player view is labelled and is hidden on inactive pages. Spinners are labelled.
  - The caption is a header. The details panel is a container with the "Close details" and escape actions.
  - The chrome stays visible for VoiceOver and Switch Control during playback. The filmstrip is hidden from VoiceOver. Glyph buttons support the large content viewer.
- [ ] **Dynamic Type and size classes:** the caption allows 2 lines at accessibility sizes in regular height. Details rows stack. Scrims and spacing have compact-height variants. A rotation refits an unzoomed photo.
- [ ] **Resource release:**
  - `onDisappear` releases decoded photos (`releaseAll` cancels the in-flight load) and the playback transport. Video pages clean up their player and temp file.
  - A lock removes the presenter (and with it the cover), bumps the session generation, deletes temp and staging files, and clears the thumbnail cache.
- [ ] **Trash variant:** decrypts from the trash location (`media.isTrashed`), shows the trash action row and adds the Deleted row.

### 2.9 Import

- [ ] **Entry points:** the Vault toolbar "Import" button (`import-media`) and the empty-state "Choose media" button (`choose-media`). Album galleries never show import.
- [ ] **Photos access:**
  - Read/write access is requested only after the user taps Import; the system prompt appears only when the status is not determined.
  - Status mapping: authorized → full; limited → limited; denied, restricted and not determined → denied.
  - Full access opens the picker directly.
  - Limited or denied access shows the dialog "Photos access needed" with buttons "Open Settings" (`UIApplication.openSettingsURLString`), "Continue with limited access" or "Continue without automatic deletion", and "Cancel". The message differs: limited means deletion works only for accessible, revalidated items; denied means import still works through the picker but automatic deletion is off.
  - Original deletion is allowed whenever access is not denied.
- [ ] **Picker:**
  - A PHPicker sheet that ignores the safe area, configured with `PHPickerConfiguration(photoLibrary: .shared())`, filter images or videos, up to 250 items, and `preferredAssetRepresentationMode = .current`.
  - `public.image` is checked before `public.movie`, so a Live Photo imports as its still image. Other results count as picker failures.
  - Cancelling or picking nothing does nothing. Otherwise the picker closes, the review sheet opens and preparation starts; if every result failed, the empty state shows the failure message.
- [ ] **Deletion eligibility** (computed at picker completion, only when deletion is allowed): an item keeps its asset identifier only if all of these hold:
  - the identifier is non-empty;
  - the provider has no `com.apple.live-photo` representation;
  - exactly one `PHAsset` can be fetched;
  - its resource profile is safe: no adjustments, not a burst, no `.photoLive` subtype, exactly one resource, of type `.photo` for images or `.video` for videos.

  Every other item counts toward "automatic deletion is unavailable for N item(s) in this selection".
- [ ] **Preparation**, in selection order:
  - Copy each file to a protected, backup-excluded, randomly named file in `tmp/QuietFrameIncoming`, keeping the sanitized extension (lowercase alphanumeric, at most 8 characters).
  - Read metadata:
    - photos: raw pixel size, and EXIF `DateTimeOriginal` (else TIFF `DateTime`) parsed as `yyyy:MM:dd HH:mm:ss` with `en_US_POSIX` in the current time zone;
    - videos: duration, transformed size, common creation date;
    - always: file size, the UTType from the extension (falling back to `public.image` / `public.movie`), and the suggested name or temp file name.
  - Make a 720-px JPEG preview at quality 0.82.
  - Unsupported or unreadable items count as "could not be prepared". A failed preview leaves a placeholder and is counted.
  - Candidates appear all at once at the end, with the combined warning ("automatic deletion is unavailable for N item(s) in this selection; N item(s) could not be prepared; N preview(s) could not be generated.").
- [ ] **Preparing screen:** a large brass `ProgressView`, serif "Preparing your selection", and "Reading metadata and creating private previews without changing the originals.", all one element "Preparing selected media". There is no bottom bar. The close button (`xmark`, "Close") cancels and dismisses. Swipe-down is allowed and also cleans up.
- [ ] **Review grid:**
  - Header: serif "Review N item(s)" and a close button in a 44 pt inset circle. At accessibility sizes, the title, hint and destination row move into the scroll content.
  - Hint: "Tap items to select them, then choose Add to album. Before importing, set where any unassigned items go." plus "Select all" / "Deselect all".
  - Adaptive grid: columns 104-160 pt (160-240 at accessibility sizes), spacing 6, cells capped at accessibility1.
  - Tiles:
    - the preview, `scaledToFill`, or a symbol placeholder;
    - a bottom album badge (`rectangle.stack` + name; `ViewThatFits` falls back to the name only);
    - a monospaced `m:ss` badge for videos;
    - a remove button (`xmark` badge 26 pt scaled, 44 pt hit area), hidden in selection mode.
  - Footer: "QuietFrame read these items without changing the originals. Nothing is encrypted until you choose Encrypt and import."
  - Warning notice: `exclamationmark.triangle`, accessibility "Warning: ...".
  - Empty state: "Nothing to import" with the message, or "Choose supported photos or videos."
- [ ] **Selection and album assignment:**
  - A tap toggles selection: a brass 3 pt ring (0.14 s in, 0.1 s out) and a brass checkmark badge that scales 0.9 → 1 (no scale with Reduce Motion). While anything is selected, unselected tiles show hollow circles.
  - The bottom bar shows "N selected", "Deselect" and "Add to album..." (`add-to-album`).
  - That opens the `AlbumDestinationPicker` titled "Add to album" (medium/large detents) with:
    - a "New album" row: an alert with an "Album name" field, Cancel / Create and the message "Albums organize encrypted media without making extra copies."; errors show the "QuietFrame" alert;
    - "Leave unassigned";
    - the album list, with a checkmark on the album shared by the whole selection. The current choice stays selectable.
  - The choice applies when the sheet finishes dismissing, and it ends the selection.
  - VoiceOver announces, 400 ms later, "N item(s) added to <album>", "left unassigned" or "added to the new album".
  - Assignments to albums that disappear are dropped. Removing an item forgets its selection and assignment and decrements the preview-failure count. Selecting and removing are blocked while importing.
- [ ] **Album label stagger:**
  - Labels of the items just assigned (`lastAssignedIDs`, in candidate order) appear 40 ms apart, capped at 400 ms.
  - Each uses a 0.22 s `timingCurve(0.23,1,0.32,1)`, moving up from the bottom while fading in; with Reduce Motion it only fades.
  - Labels leave with a 0.1 s fade. Labels on the sealing grid do not animate.
- [ ] **Default destination:**
  - A Menu with a Picker: "Vault (no album)" plus albums by position.
  - Labelled "Destination", or "Unassigned items" once some items are assigned, followed by the value and `chevron.up.chevron.down`.
  - Shown only when some candidate is unassigned: in the bottom bar, or in the scroll content at accessibility sizes. It carries an accessibility label and value.
- [ ] **Start:** "Encrypt and import" (`aperturePrimary`, `begin-import`) clears the selection, snapshots each item's destination (its assignment, else the default), sets progress to 0/N and starts the import.
  - If the import cannot start (for example cancelled while waiting for the gate, or a persistence failure), the review grid returns with the candidates kept and the error shown as a warning.
  - A `CancellationError` there shows "The media could not be imported.". **Quirk.**
- [ ] **Sheet protection:**
  - Interactive dismissal is disabled and the drag indicator hidden while importing, or once any assignment exists.
  - `presentationBackground` elevated (dusk), corner radius 28.
  - The ground is dusk for preparing and review, night for importing and the result. The close button is hidden while importing.
- [ ] **Progress and sealing:**
  - Header: serif "Encrypting X of N" (X = min(completed + 1, N), monospaced) and "You can cancel safely. A partially encrypted item is removed before the import stops."
  - A 4 pt brass bar scaled from the leading edge, linear 0.15 s per update (none with Reduce Motion), labelled "Import progress" with a percent value and the `updatesFrequently` trait.
  - Tile states:
    - waiting: 75% opacity;
    - sealing: a brass sweep proportional to `currentItemFraction / 0.9` (Reduce Motion: a 35% brass fade);
    - sealed: a 58% night overlay with `lock.fill`, 0.16 s ease-out, scaling 0.9 → 1.
  - VoiceOver per tile: "<filename or Photos/Videos>, [video duration m:ss,] album X / unassigned, waiting / encrypting / done".
  - The grid auto-scrolls to the sealing tile with the 0.35 s drawer curve (instantly with Reduce Motion).
  - The bottom bar shows "Cancel import" (`apertureSecondary`, destructive role).
  - Duplicates and failures also end as sealed and "done". **Quirk.**
- [ ] **Per-item pipeline semantics**, in source order:
  - Free space must exceed size + 32 MiB; otherwise the item counts as Failed and the loop continues.
  - Encrypt in 1 MiB AES-GCM chunks.
  - Exact-duplicate check by keyed fingerprint against every item, including Trash. A duplicate is skipped, counted, never inserted and never offered for deletion. Within one batch, the second identical file is the duplicate.
  - Store an encrypted thumbnail. If that fails, the item is imported without a thumbnail and the failure is counted.
  - Insert metadata into the per-item album or the default album. A missing album gives `persistenceFailure`; the item counts as Failed and both files are removed.
  - `importedAt = Date()` per item, so values strictly increase in source order. The album's `modifiedAt` is bumped.
  - The `ImportRecord` stores requested, imported, duplicate and failed counts, timestamps, and a status: cancelled, failed (when every item failed) or completed.
- [ ] **Cancel:** stops at the next 1 MiB chunk or the next item. The partial item is removed and finished items stay. The result shows "Import cancelled" / "Finished items remain protected; incomplete work was removed."
- [ ] **Lock during import:**
  - The UI is torn down instantly, and crypto is revoked at the next chunk.
  - An item past encryption is rolled back: metadata and files.
  - Every incoming copy, staging partial and temp file is deleted.
  - Launch removes leftovers, and reconcile deletes orphan ciphertext after unlock.
- [ ] **Result screen:**
  - Title "Import complete" or "Import cancelled" (`quietScreenTitle`). Description: "Finished items remain protected; incomplete work was removed.", "No new media was added to your vault." or "New media is encrypted and available in All Media."
  - Metrics card: Imported, "Duplicates skipped" ("Already in the vault") and Failed (including picker and preparation failures). Each is a combined element, stacked at accessibility sizes.
  - Notices:
    - "N preview(s) could not be created; the encrypted originals remain available.";
    - when deletion is offered, the emphasized warning "Your vault copies are not in iCloud backup. If you delete the originals, the vault holds the only copy.";
    - the user message, for example "Automatic deletion was not offered because every imported item could not be matched safely to a replaceable Photos asset."
  - A success haptic plays when at least one item was imported.
  - Buttons: "Done", plus "Delete imported originals from Photos" (`apertureDestructive`, disabled while deleting) when deletion is offered.
  - Dismissal cleans up and refreshes the gallery.
- [ ] **Deleting originals:**
  - Offered only when `importedCount > 0` and every imported item has an eligible identifier. That also applies after a cancelled import.
  - The dialog appears automatically after the summary (after one `Task.yield`):
    - title "Delete originals from Photos?";
    - message "iOS will ask for permission. Deleted items may remain in the Photos app's Recently Deleted album. QuietFrame never deletes originals automatically. Your vault copies are not in iCloud backup. If you delete the originals, the vault holds the only copy.";
    - buttons "Delete from Photos" (destructive) and "Keep originals".
  - The flow:
    1. dedupe the identifiers and re-authorize;
    2. fetch all assets in one batch; a count mismatch gives `limitedPhotosAccess` or `fileOperationFailed`;
    3. revalidate each resource profile;
    4. call `PHPhotoLibrary` `deleteAssets`, which shows the system confirmation.
  - Messages:
    - success: "The selected originals were moved to Recently Deleted in Photos.";
    - missing identifiers: "iOS did not provide a safe reference for every imported original. QuietFrame did not delete anything; remove those items manually in Photos.";
    - errors: VaultError text, falling back to `fileOperationFailed`.
- [ ] **Accessibility:**
  - Review tiles:
    - label: filename (or "Photos" / "Videos"), duration, and album or "unassigned";
    - hint: "Toggles selection for adding to an album";
    - the `isSelected` trait and a custom action "Remove";
    - the remove button is labelled "Remove <filename|item>".
  - Headers carry the header trait. Metrics and notices are combined elements. The progress bar is a single element and each sealing tile one element. Announcements are posted.
  - Layouts change at accessibility sizes.
  - Reduce Motion variants cover the label insertion, the checkmark and lock scale, the sweep, the bar and the auto-scroll.
- [ ] **File hygiene:**
  - Incoming copies are deleted when a candidate is removed, when preparation is cancelled or closed, on sheet dismissal (`cleanupIfIdle`), at batch end, on lock and at launch. Removal only deletes files inside a directory named `QuietFrameIncoming`.
  - The thumbnail temp file is deleted right after it is encrypted.
  - Staging partials are deleted on failure, on lock and at launch.

### 2.10 Export

- [ ] **Share** (from the gallery selection bar and the viewer):
  - Decrypts every selected item to a protected temp file named `<random UUID>.<preferred extension>`, never the original filename, then presents `UIActivityViewController`. Items whose type fell back to `public.image` / `public.movie` get no extension. **Quirk.**
  - Temp files are deleted on activity completion, sheet dismissal, lease deinit and lock.
  - No progress, no cancel, all or nothing.
  - Errors: "Select at least one item to export.", "One or more selected items are no longer available.", `corruptedFile`, `insufficientStorage`, `exportFailed`.
  - Trashed items export from the trash location, resolved after the gate is acquired.
- [ ] **Save to Photos:**
  - Add-only authorization is requested before anything is decrypted. Denial shows "Photos access was denied. You can change it in Settings.".
  - One Photos transaction adds one asset per item (`.photo` or `.video` resource), with `creationDate = originalCreationDate`.
  - Temp files are deleted afterwards.
  - Messages: "Saved N item(s) to Photos." (gallery) and "Saved to Photos." (viewer).
  - The Photos library is written only on this explicit action.
- [ ] **Share sheet bridge:** its completion closure (lease cleanup) runs exactly once, from `completionWithItemsHandler` or on dismantle.
- [ ] **Export behavior page** (Settings, large title "Export behavior"):
  - Media quality Original; Compression None; Video transcoding None; Embedded metadata Preserved; Photos creation date Preserved; plus an explanatory note.
  - Width at most the readable width + 2 × page padding.

### 2.11 Albums tab

- [ ] **Collections section** (serif "Collections"):
  - Rows: All Media (`photo.on.rectangle`), Recently Added (`clock`; "<n> items from the last 30 days"), Favorites (`heart`).
  - Each is an `AlbumsListRow` with an `AlbumsGlyph` (slate rounded tile) and "1 item" / "<n formatted> items".
  - Each row is one element, "<title>, <detail>", and pushes the matching gallery.
  - Counts exclude trashed items and update after every save.
- [ ] **"Your albums" section:**
  - Serif header with a count capsule (monospaced, accessibility label "<n> albums").
  - Footer: "Albums organize encrypted media without making extra copies."
  - With no albums, a brass row "Create an album to organize private media" (`rectangle.stack.badge.plus`) opens the New album alert.
- [ ] **Album row:**
  - `AlbumCover` at 40 pt (56 pt when stacked at accessibility sizes). It shows, in order of preference:
    1. the cover item, if `coverMediaID` is a non-trashed member;
    2. the first non-trashed member of the unordered relationship, which is arbitrary and can change between launches (**Quirk**);
    3. a `rectangle.stack` glyph.
  - While loading, the placeholder shows the media-type symbol. The decrypted thumbnail reloads when the cover or thumbnail id changes.
  - Then the name and a trailing count of non-trashed items. The row is one element, "<name>, <n items>", and a tap pushes the album gallery.
  - Context menu: Rename (`pencil`) and Delete (`trash`, destructive), mirrored by the VoiceOver actions "Rename" and "Delete".
- [ ] **Create:**
  - The toolbar "+" (`new-album`) or the empty row opens the alert "New album" with an "Album name" field, Cancel / Create and the albums message.
  - The name is trimmed and must be 1-80 characters ("Album names must contain 1 to 80 characters.") and unique ignoring case and diacritics ("An album with this name already exists.").
  - The new album gets position max + 1. Success plays a haptic.
  - Albums can also be created from the import picker.
- [ ] **Rename:** the alert "Rename album", prefilled, with Cancel / Rename. Same validation; a conflict or missing album gives "This album name is unavailable.". It bumps `modifiedAt`.
- [ ] **Delete:**
  - Dialog "Delete <name>?" with "Delete album, keep media", a destructive "Delete album and move media to Trash" and Cancel. Message: "Keeping media removes only the album. Moving media to Trash can be undone until the items expire."
  - Runs under the gate. In trash mode, files move first (moved back on failure), and each item gets `previousAlbumID`, `trashedAt` and `modifiedAt`.
  - In both modes the items lose the album and the album row is deleted.
  - Success plays a haptic. Errors show "QuietFrame" (default "The album could not be updated.").
- [ ] **Sort menu** "Sort albums" (`arrow.up.arrow.down`):
  - Options: Manual (position), Name (`localizedStandardCompare` ascending), Date created (newest first), Last modified (newest first, the default).
  - Saved immediately. A failure shows an alert but does not roll back. **Quirk.**
- [ ] **Reorder:**
  - "Reorder albums" (`line.3.horizontal`) is disabled with fewer than 2 albums.
  - The sheet is permanently in edit mode with drag handles, Cancel and Done, and starts in the current displayed order. Dusk background, 28 pt radius.
  - Done saves positions 0..n−1, switches the sort to Manual and plays a success haptic.
  - An invalid set gives "The album order is invalid."; with zero albums it returns early without switching; a failed save shows "The album order could not be saved.".
- [ ] **'Last modified' bump rules:** `album.modifiedAt` changes when:
  - an item is imported into the album;
  - the album is renamed;
  - media moves into or out of it;
  - its cover is set;
  - a member's favourite is toggled;
  - an item is trashed from it;
  - an item is restored into it.

  Reordering does not bump it.

### 2.12 Trash tab

- [ ] **Grid:** a `GalleryViewModel` over trashed items, sorted by Date Imported (not by deletion date), with the filter and sort menu. Tiles show the deletion date and VoiceOver reads ", deleted <date>".
- [ ] **Retention banner** (when not empty): clock icon and "Items are permanently deleted after N days.", using the raw `trashRetentionDays`.
- [ ] **On every appearance:** purge expired items (an error shows an alert), then refresh.
- [ ] **Toolbar:**
  - Filter and sort.
  - Select (`checkmark.circle`, disabled when empty).
  - "Empty Trash" (`trash.slash`, ember, disabled when empty or working), confirmed with "Empty Trash?" / "Every encrypted item in Trash will be permanently removed."
- [ ] **Selection bar:** three `ViewThatFits` layouts, minimum height 64, separator stroke, label style that turns horizontal at accessibility sizes.
  - "Restore" (`arrow.uturn.backward`).
  - "Delete permanently", confirmed with "Permanently delete selected media?" / "This removes encrypted files from this device and cannot be undone."
- [ ] **After an operation:** operations run one at a time (`isWorking`). Afterwards the selection ends, the whole thumbnail cache is cleared, the grid refreshes and the success haptic plays. Errors use Trash's own alert.
- [ ] **Restore:**
  - Runs under the gate. Files move trash → media first (moved back on failure).
  - Each item returns to its previous album if that album still exists, otherwise to no album. The restored album's `modifiedAt` is bumped, `previousAlbumID` is cleared and `trashedAt` is set to nil.
  - One save. If any selected item is not trashed or is missing: `persistenceFailure`.
- [ ] **Permanent delete and Empty Trash:**
  - Run under the gate and apply only to trashed items.
  - Metadata is deleted and saved first. Then, per item, the original is deleted from `trash`, then its thumbnail.
  - If any file deletion failed: "The secure file operation could not be completed." The orphans are left for reconcile.
- [ ] **Purge:**
  - Deletes items with `trashedAt <= now − trashRetentionDays` (calendar days, raw value; 30 when no settings row exists) and returns the count.
  - Runs after every unlock or auto-open (as part of maintenance) and on every Trash appearance.
- [ ] **Viewer:** tapping a tile opens the Trash variant of the viewer, with the zoom transition.

### 2.13 Settings

- [ ] **List:** `insetGrouped`, section spacing 28, `QuietSettingsLabelStyle` (28-pt mist icon column), `SettingsValueStyle`, large serif "Settings".
- [ ] **Privacy facts row:** "Analytics and tracking: Off" and "Cloud sync: Off". `ViewThatFits` switches HStack → VStack. Clear background, no separator, zero insets.
- [ ] **Security header and footer:** the header is a small sealed iris without a ring (`@ScaledMetric` 18) plus a serif "Security". The footer explains the app-switcher cover and Auto-Lock.
- [ ] **Passcode mode:**
  - "App passcode" On.
  - A biometrics toggle titled Face ID, Touch ID or Biometrics (`faceid` / `touchid`), with the hint "Uses biometrics currently enrolled on this device":
    - it is disabled without biometric hardware and shows the persisted value;
    - turning it on calls `setBiometricsEnabled`, which prompts with "Enable biometric unlock for QuietFrame";
    - it requires passcode mode ("Turn on app passcode protection before enabling biometrics.") and hardware ("Biometric authentication is not available.");
    - a failed save rolls back and reverts the Keychain, and failures show an alert.
  - "Change passcode" (sheet).
  - The Auto-Lock picker: Immediately / After 30 Seconds / After 1 Minute / After 5 Minutes.
  - "Lock QuietFrame now" (`lock-now`), which locks instantly.
  - A destructive "Turn off app passcode" (sheet).
- [ ] **No-passcode mode:** "App passcode" Off, "Set a passcode" (sheet), and the footnote "Media remains encrypted, but QuietFrame opens whenever your iPhone is unlocked."
- [ ] **Vault section:**
  - Trash retention picker: 7 / 15 / 30 Days.
  - Thumbnail size: Compact / Comfortable / Large. It changes only the column width; stored thumbnails stay 720 px.
  - Changes save immediately (the setters bump `modifiedAt`). A failure rolls back and shows "Vault changes could not be saved.".
- [ ] **Privacy section links:** Storage usage, Export behavior, "How QuietFrame protects you".
- [ ] **Danger section:**
  - A destructive "Reset QuietFrame" (hint "Permanently deletes encrypted media and keys after additional confirmations") opens the dialog "Reset QuietFrame?", whose message depends on the mode.
  - "Continue to reset" opens ResetApplicationView in passcode mode, or RecoveryResetView in no-passcode mode. Interactive dismiss is disabled while working.
- [ ] **Change passcode sheet:**
  - Inline title "Change passcode", dusk toolbar background, Cancel and "Change".
  - Step chips Current / New / Confirm:
    - a brass check appears when a step has 6 digits;
    - the selected chip is a night capsule, and tapping a chip jumps to that step;
    - labels "Current passcode", "New passcode", "Confirm new passcode"; values Entered / Not entered; the `isSelected` trait.
  - An error card, and a serif prompt per step.
  - The field is recreated per step (`.id(step)`). Its iris is 88 below 640 pt of height, otherwise 140. It advances automatically.
  - The footer says media is not re-encrypted.
  - "Change" is enabled when all three entries have 6 digits and nothing is running. A failure shows the message, clears Current and returns to that step; success dismisses. Steps animate with `.snappy` unless Reduce Motion is on.
  - Semantics:
    - the current passcode is verified, and failures count toward the lockout;
    - the same key is re-wrapped with a new salt (2 derivations) and replaced with one `SecItemUpdate`;
    - the attempt state is cleared and the session re-unlocked, which bumps the generation.
- [ ] **Set passcode sheet:**
  - Steps New / Confirm ("New passcode" / "Confirm passcode"), prompts "Choose a passcode" / "Confirm the passcode", iris 88 / 140 at the 640 pt threshold.
  - "Set" is enabled when both entries have 6 digits. It calls `addPasscode`: wrap the existing key, write the envelope, then delete the raw key (rolling back the envelope if that fails), then re-unlock.
  - The footer says the key is re-wrapped and no media is re-encrypted.
- [ ] **Turn off passcode sheet:**
  - A toggle "I understand anyone using my unlocked iPhone can open the vault", an error card, and a panel with "Enter your current passcode", a field (iris 88 below 740 pt, otherwise 140) and a destructive "Turn off app passcode" (`apertureDestructive`).
  - The button is enabled when the toggle is on and 6 digits are entered. It calls `removePasscode`:
    1. honour the lockout and count failures;
    2. store the raw key, delete the envelope (rolling back on failure), delete the biometric item and the attempt state, and re-unlock;
    3. switch to mode `.none` and turn biometrics off.
  - A failure clears the entry; success dismisses. The footer explains no-passcode mode.
- [ ] **ResetApplicationView** (passcode mode):
  - A Form with the inline title "Final reset confirmation" and Cancel.
  - "This permanently removes": All encrypted photos and videos; Albums, favorites, tags, and Trash; Passcode data and encryption keys.
  - The toggle "I understand this cannot be undone", "Type RESET", and a SecureField "Current six-digit passcode" (number pad, filtered to 6 digits).
  - A footer on the deletion order, and an error section.
  - "Permanently reset QuietFrame" (`confirm-reset`; ember when enabled, mist when disabled) needs the toggle, the text RESET, 6 digits and no work in progress.
  - It calls `resetApplication`, which re-verifies the passcode through `unlock` (failures counted). Success dismisses and onboarding shows; failure shows the message and clears the passcode.
- [ ] **RecoveryResetView:**
  - Inline title "Erase unrecoverable vault", Cancel.
  - `QuietIntroduction` (`key.slash`), the toggle "I understand all vault media will be lost", and the field "Type ERASE" (capitalized characters, no autocorrection).
  - "Authenticate and erase vault" (semibold; ember when enabled, mist when disabled) needs the toggle, exactly ERASE and no work in progress.
  - It runs device-owner authentication ("Authenticate to permanently erase the unrecoverable QuietFrame vault"), erases, dismisses, and onboarding shows. A failure shows an error section.
  - Reached from "Forgot passcode?", the recovery screen, and the Settings reset in no-passcode mode.
- [ ] **Erase sequence** (both resets), under the gate:
  1. begin the journal;
  2. set `.locked` and lock the session;
  3. delete the 4 Keychain accounts;
  4. remove all encrypted files and recreate the empty directories;
  5. delete every VaultMedia, VaultAlbum, ImportRecord and AppSettings row;
  6. insert a fresh AppSettings and save;
  7. finish the journal;
  8. set mode `.notConfigured` and state `.needsOnboarding`.

  A `CancellationError` returns false. Any other error after authentication goes to `.recoveryRequired`.
- [ ] **Storage usage page** (large title "Storage usage"):
  - Runs the analysis on every appearance and on pull-to-refresh. While loading: "Analyzing encrypted storage".
  - Total encrypted bytes (`ByteCountFormatter` `.file`, 44-pt scaled monospaced) with "Encrypted vault".
  - "Breakdown" card: Photos, Videos, Private previews and Trash, each with a byte count and a share bar (minimum 6-pt fill when above zero). Each row is one element "<Title> storage" with the value "<bytes>, <n>% of the vault".
  - Media and Albums count cards, side by side, stacked at accessibility sizes.
  - "Largest files": up to 20 non-trashed items ranked by metadata `byteCount` (plaintext size). Each shows a type icon, the display name ("Private Photo" / "Private Video" without a filename) and the size; label = name, value "<Photo|Video>, <bytes>". Rows are not tappable. With no items: "No active media".
  - Footnote: "Actual encrypted files and private previews stored in the app sandbox."
  - Error state: `ContentUnavailableView` "Storage unavailable" with the message.
  - Semantics:
    - only logical sizes of referenced encrypted files count;
    - trashed items count under Trash whatever their type;
    - thumbnails of all items, trashed included, count as Private previews;
    - the media count includes trashed items, and the album count is all albums;
    - one missing referenced file fails the whole analysis (**Quirk**).
- [ ] **"How QuietFrame protects you"** (large title "Privacy"): `QuietIntroduction` "Private by construction" (`hand.raised.square.fill`) and five rows, each one element with fixed copy: On-device encryption, Photos access, Backups and device lock, Screenshots and recording, Exports.

### 2.14 Storage, security and background behaviour

- [ ] **Encrypted storage (`store`):**
  - Picks a random lowercase-UUID identifier and encrypts to `staging/<id>.partial` with complete protection.
  - Protects and excludes the partial from backup, renames it to `media|thumbnails/<id>.qfe`, then protects and excludes again.
  - On any failure both paths are removed.
  - Returns the identifier, plaintext size and fingerprint.
  - Errors: empty input → `unsupportedFileType`; lock → `authenticationRequired`; cancellation → `importCancelled`.
- [ ] **Integrity:** the decoder rejects all of these with `corruptedFile` ("This item could not be verified or opened."):
  - a wrong magic, version, flags or reserved field;
  - a chunk size outside 64 KiB-16 MiB, or a zero length;
  - any modified byte;
  - truncation, reordered chunks or trailing bytes.
- [ ] **In-memory decryption:** caps of 16 MiB for thumbnails, 512 MiB for viewer photos and 256 MiB by default.
  - Exceeding the cap → `insufficientStorage`.
  - A missing file → `corruptedFile`.
  - Cancellation → `CancellationError`.
- [ ] **Temporary leases:**
  - Check the file exists (`corruptedFile` if not).
  - Check that `volumeAvailableCapacityForImportantUsage` exceeds the encrypted size + 32 MiB (`insufficientStorage` if not).
  - Decrypt fully to `Caches/QuietFrameTemporary/<uuid>.<ext of up to 8 [a-z0-9] characters>`, apply complete protection and backup exclusion, and fsync.
  - The lease deletes the file exactly once, on `cleanup()` or `deinit` (guarded by an NSLock).
  - Used by: active-page video, Share, Save to Photos.
- [ ] **File moves:**
  - Rename without decrypting. Refuse when the source is missing or the destination exists (`fileOperationFailed`).
  - Re-apply protection, and roll the rename back if that fails.
  - Callers move the files first and save afterwards; if the save fails, the files move back in reverse order.
- [ ] **Deletes:** idempotent. Metadata goes first, then files.
- [ ] **`allIdentifiers`:** only non-hidden `<uuid>.qfe` entries, with the case kept.
- [ ] **Post-unlock maintenance:** runs after every unlock path (passcode, biometrics, creation, silent open and resume), under the gate, and is awaited before `.unlocked`.
  - Reconcile, then purge.
  - Reconcile:
    - an active item's file found in `trash` moves back to `media`;
    - a trashed item's file found in `media` moves to `trash`;
    - missing files are only counted;
    - unreferenced UUID `.qfe` files in media, trash and thumbnails are deleted;
    - files without a UUID name are ignored;
    - the result is discarded.
  - A failure keeps the vault locked with an error (passcode mode) or shows the retry screen (no-passcode mode).
- [ ] **Temp hygiene:**
  - `cleanupTemporaryFiles` (temp and staging) runs at init and on every lock. Incoming copies are removed after init (RootView `.task`) and on lock.
  - Every created file and directory gets `FileProtectionType.complete`, `isExcludedFromBackup` and a random UUID name.
- [ ] **Operation gate:** one FIFO, non-reentrant async mutex.
  - Gated: import (the whole batch), Share and Save to Photos, every Trash operation and purge, album delete, reconcile, reset.
  - A cancelled waiter is removed and throws `CancellationError`. The lock is released in a `defer`, and holders call the private `*Exclusively` helpers.
  - Not gated: album create, rename, reorder, move and cover; favourites; storage analysis; reads.
- [ ] **Duplicate token:** the SHA-256 of the plaintext, HMAC-ed with `HKDF(master, salt: empty, info: "QuietFrame.deduplication-key.v1")`, as 64 lowercase hex characters. Stored in the unique `contentFingerprint`. Re-encoded copies do not match.
- [ ] **Encryption progress:** reported after each 1 MiB chunk as processed / total. The importer maps it to `currentItemFraction` × 0.9.
- [ ] **Error catalogue:** 23 `VaultError` cases with user-facing strings. The UI maps errors with `(error as? VaultError)?.localizedDescription ?? <fallback>`. `Equatable` drives control flow: `missingEncryptionKey` leads to recovery, and the `temporarilyLocked` date feeds the lockout date.
- [ ] **Settings defaults:**
  - Biometrics off, Immediately, 30 days, appearance `system` (unused; the app is always dark), Comfortable, album sort Last modified, album media direction Newest First.
  - Unknown raw values fall back to these defaults, and the setters bump `modifiedAt`.
- [ ] **Media display metadata:**
  - `displayName` falls back to "Private Photo" / "Private Video".
  - An unknown type is treated as a photo.
  - The `accessibilitySummary` format is given in 2.7.
- [ ] **`ImportRecord`:** written at import begin and finish, never read.
- [ ] **Lock and in-flight revocation:** see 2.5. The session generation also bumps on every re-wrap (add, remove or change passcode, normal reset), which revokes in-flight decrypts.

### 2.15 Platform, theme and accessibility contract

- [ ] **Theme:**
  - Always dark (`.preferredColorScheme(.dark)`), brass tint, moon foreground.
  - `applyGlobalAppearance()` runs at launch:
    - opaque night navigation bars in every appearance, no shadow, brass bar tint;
    - New York serif titles (17 semibold, 34 regular large), scaled once at launch, so navigation titles do not follow Dynamic Type changes until relaunch (**Quirk**);
    - an opaque dusk tab bar with a slate shadow, mist normal items, a brass selected icon and moon selected title (stacked, inline and compact-inline);
    - brass `UISwitch`.
- [ ] **Tokens and palette:**
  - Radius 16 / 12 / 10 / 28; page padding 24; spacing 28 / 16 / 8; grid spacing 6; control height 44; primary button 52; readable width 560.
  - Colours: night #131B2E, dusk #1C2740, slate #2A3757, moon #ECEFF6, mist #A3AEC4, brass #E3BE7C, ember #F2937E; `vaultGradient` night → #172138.
  - Type: New York for titles, SF Pro elsewhere, monospaced digits for numbers.
  - Pill buttons (pressed 0.78, disabled 0.45):
    - `aperturePrimary`: brass, minimum height 52;
    - `apertureSecondary`: dusk, minimum 48;
    - `apertureDestructive`: dusk with ember text, minimum 48.
  - Modifiers and components: `quietCard`, `quietFormStyle`, `quietRows`, `quietScreenTitle`, `QuietSymbol`, `QuietIntroduction`.
- [ ] **ApertureIris / ApertureMark geometry:**
  - Blade keyframes in a 200×200 space: arc radius 88, 24 arc steps, 6 blades at 60°.
  - Ring inset 4·scale with a 2·scale slate stroke.
  - Filled blades are brass (ember on error) with 2.5·scale night seams; empty blades are dusk with 1.5·scale mist outlines.
  - The mark adds viewfinder corners: length 12.5% of the side, radius 36% of the length, 2.5·scale mist stroke.
  - Both are hidden from accessibility.
- [ ] **Dynamic Type and Reduce Motion:**
  - Dynamic Type adaptations are listed per screen above. Every screen still scrolls on a 375×667 iPhone SE.
  - With Reduce Motion: no flourish, shake, blade animation, step animation, flight or scaling; the vault scale-in becomes a 0.2 s fade.
- [ ] **Haptics:**
  - Success after album create, album reorder, album delete, an import with at least one imported item, and Trash operations.
  - A light impact on every change of the passcode digit count.
  - Each call creates a fresh UIKit generator.
- [ ] **Accessibility identifiers (19):** `migration-error`, `vault-retry-required`, `launch`, `key-recovery-required`, `main-tabs`, `onboarding`, `start-setup`, `skip-passcode`, `unlock-screen`, `biometric-unlock`, `privacy-shield`, `import-media`, `choose-media`, `new-album`, `lock-now`, `confirm-reset`, `add-to-album`, `begin-import`, `media-viewer`. The UI test relies on 8 of them.
- [ ] **iPad multiple windows** (the built Info.plist has `UIApplicationSupportsMultipleScenes = true`):
  - All windows share one `AppModel`, `AppDependencies`, coordinator and thumbnail cache.
  - Each window has its own gate screens, shield window, scene handling and galleries.
  - Any window going to the background can lock all of them.
  - Opening a window runs the incoming-file cleanup, which deletes another window's in-flight import inputs. This is a defect (P45).
- [ ] **Orientation and multitasking:**
  - iPhone supports portrait and landscape left/right, but not upside down. iPad supports all four orientations, plus Split View, Slide Over and Stage Manager (no `UIRequiresFullScreen`).
  - Grid columns adapt, and the viewer uses compact-height scrims.
  - Authentication screens use a compact layout below 700 pt of height; the passcode sheets switch below 640 or 740 pt.
- [ ] **Hardware keyboard and pointer:**
  - Passcode digits and delete can be typed, and the field focuses itself.
  - A secondary click opens the context menus on tiles and album rows.
  - `UIApplicationSupportsIndirectInputEvents = true`.
- [ ] **App icon:** three 1024-px SVG variants (Any, Dark, Tinted); converting them to PNG must keep all three. AccentColor #E3BE7C.

### 2.16 Other quirks and defects to preserve or fix deliberately

These were observed in passing. Each one stays as it is unless 6.4 approves a fix.

**Gallery and paging**

- Offset paging can skip or repeat items after an in-place favourite change in a Favorites view, or as the Recently Added cutoff moves. A refresh corrects it.
- A filter or search change can race a paging task and append mixed results with duplicate IDs (`loadNextIfNeeded` has no generation guard).
- Toggling a favourite does not remove the item from a Favorites view until the next refresh.
- Search uses a 250 ms debounce. Once the debounce fires, the synchronous search cannot be cancelled.

**Trash**

- Leaving the Trash tab while its purge waits for the gate shows the generic "secure file operation" alert.
- The first Trash visit shows "Trash is empty" for as long as the purge takes.

**Thumbnails**

- After a Trash operation, live Trash tiles keep their images while the cache is empty. Opening one then fades instead of zooming and has no video poster. Tiles that were loading during the clear stay placeholders until they reappear.
- A purge never evicts the in-memory thumbnails of the items it deletes.
- In `ThumbnailService`, an older waiter can delete a newer in-flight entry after `clearCache()`, causing a duplicate decrypt. Failed decrypts are retried on every appearance.
- The opening zoom plays only if the thumbnail is still cached. Whether it falls back to a fade is unpredictable.

**Passcode, lock and lifecycle**

- Change, Set and Turn off passcode can submit twice, because `isWorking` is not set. The second submit records a spurious failed attempt.
- `removePasscode` can report failure after the Keychain has already switched to no-passcode mode.
- Likely, not confirmed: in no-passcode mode, a lifecycle task cancelled during maintenance can leave the app stuck on the retry screen.
- Lock while the viewer is open relies on SwiftUI dismissing the cover implicitly. Verify on a device that the dismissal is not animated.

**Viewer**

- During the 0.2 s fade after a permanent delete, the viewer still holds the deleted model. SwiftData can trap on reads of deleted models.

**Errors and messages**

- `decryptFile` maps a write failure such as ENOSPC to `corruptedFile`. A cancelled export inside decryption shows "The import was cancelled.".

**Import**

- After a cancelled import, the deletion dialog still appears automatically. Tapping Done while the deletion runs loses its result message.
- `ImportPreviewView`'s `destinationAlbumID` is not cleared when that album is deleted, so every item then fails.
- `NSItemProvider` loading has no timeout.

**Albums**

- `AlbumsScreen.albumSortBinding` saves without rolling back on failure.

**Known issues (CLAUDE.md)**

- Hosted reset tests write the real reset-journal marker.
- The app icon is SVG only.
- `ITSAppUsesNonExemptEncryption` is missing.

---

## 3. Performance problems and evidence

**Nothing below has been profiled.** Severity and confidence come from code inspection, and the verification pass corrected them where needed (section 3.4). Each "P" issue merges the matching findings of the six area audits; their original ids are listed with the evidence. The "Measured by" column names the benchmark tests in section 7 (B1 to B14).

Ranking: severity first, then how many users and screens are affected, then confidence. P45 (a correctness defect) and P46 (install size) are not runtime performance problems, so they are listed last whatever their severity.

### 3.1 Ranked table

| Rank | ID | Title | Main location | Sev. | Conf. | Impact at 1k / 10k items | Measured by |
|---|---|---|---|---|---|---|---|
| 1 | P01 | Thumbnails are decoded on the main thread at first draw | `ThumbnailService.swift:31-33`, `MediaThumbnailView.swift:52-65` | High | Certain (ms likely) | Same at any library size: ~1-4 ms of main thread per newly shown tile. A fling reveals 125-200 tiles/s. The first screen after unlock costs ~40-110 ms on iPhone and ~3× that on iPad | B1 `testFirstDisplayCostOf60Thumbnails`, B3 `testScrollCost1k` |
| 2 | P02 | The thumbnail cache holds only ~32-57 full 720-px bitmaps, and the viewer depends on it | `ThumbnailService.swift:13-14,37`, `ThumbnailGenerator.swift:14` | High | Certain | Same at any library size: the cache holds ~2 iPhone screens and less than 1 iPad screen. Scrolling back decrypts again; zoom and poster fall back on misses; realized iPad tiles pin ~140-240 MB | B1 `testThumbnailBytesAndRetention`, B3 `testScrollBackDecrypts1k`, `testReappearanceDecrypts` |
| 3 | P03 | Unlock waits for a full-library reconcile plus purge on the main actor, and behind any gate holder | `AppDependencies.swift:96-99`, `VaultLockCoordinator.swift:79-82,153-158,175-181,188-194`, `StorageReconciliationService.swift:26-81` | High | Likely | 1k: ~20-60 ms; 10k: ~150-500 ms per unlock and per no-passcode foreground, plus seconds behind a running gate holder | B4 `testReconcile1k/10k`, `testUnlockToUnlocked10k`, `testNoPasscodeResume10k`, `testUnlockWaitsBehindGateHolder` |
| 4 | P04 | Search fetches and filters the whole scope for every query, every page and every refresh | `VaultRepository.swift:150-175` | High | Certain (ms likely) | 1k: ~20-80 ms per call; 10k: ~0.2-0.8 s per call, repeated for each page and each refresh | B2 `testSearchNoHits1k/10k`, `testSearchScroll5Pages10k`, `testRefreshWithSearch10k` |
| 5 | P05 | The Albums tab fetches every active item for three counts, and album rows walk their relationship | `AlbumsScreen.swift:9,110-112,169,233-236`, `VaultAlbum.swift:31-33` | High | Likely | 1k: ~5-20 ms per render. 10k: ~50-200 ms on the first visit after each unlock, ~20k tracked reads per render, ~10 MB held | B5 `testAlbumsFirstRender10k`, `testAlbumsRenderPerSave10k` |
| 6 | P06 | The viewer does O(loaded items) work per evaluation, which runs on every drag frame and twice per page change | `MediaViewer.swift:89-102,124,259-281,351-371` | High (deep scroll) | Likely | 1k loaded: ~2-7 ms per evaluation, so the drag drops frames. 10k loaded: ~20-70 ms per evaluation, so the drag runs at ~15-40 fps | B6 `testViewerUpdate100/1k/10k` |
| 7 | P07 | Video plays only after a whole-file decrypt to disk plus fsync, and re-activating the page repeats it | `SecureMediaPage.swift:177-243`, `SecureFileStorageService.swift:127-160` | High | Certain (likely for the swipe-back repeat) | Same at any library size: ~0.2 s per 100 MB, 1-2 s per 500 MB, ≥ 4 s per 2 GB (device estimates). Needs free space of size + 32 MiB | B7 `testTemporaryDecryptedFile128MiB`, `testTimeToPlayable128MiB`, `testSwipeAwayAndBackDecryptCount` |
| 8 | P08 | Single-item Trash, Restore, Delete and Move fetch the whole VaultMedia table on main | `TrashService.swift:171-174`, `VaultRepository.swift:228-231` | High | Certain (ms likely) | 1k: ~10-30 ms; 10k: ~100-300 ms stall per action | B11 `testMoveOneToTrash10k`, `testRestoreOne10k`, `testPermanentDeleteOne10k`, `testMoveOneToAlbum10k` |
| 9 | P09 | Import preparation runs one item at a time and publishes nothing until the end | `ImportViewModel.swift:63-150` | High | Likely | Depends on selection size: 250 photos ≈ 15-75 s of an indeterminate spinner, 100 photos ≈ 6-30 s | B10 `testPrepare24Items` |
| 10 | P10 | The viewer holds up to three 4096-px bitmaps with no memory-warning handling | `ViewerPhotoLoader.swift:7,62-75,121-147` | Medium | Certain (resident) | ~146-151 MB resident while browsing photos; ~200-250 MB or more while paging | B6 `testPhotoWindowBytes12MP/48MP` |
| 11 | P11 | Refresh re-fetches every loaded row on viewer close, tab return, import, move and trash | `GalleryViewModel.swift:55-76` | Medium | Certain (rows), likely (ms) | Rows fetched = loaded + 1. 1k loaded: ~10-20 ms; 10k loaded: ~80-150 ms; with a search active, a full search | B2 `testRefreshLoaded5kOf10k` |
| 12 | P12 | Offset paging scans and sorts for every page, never loads ahead, and sorts strings through a collation | `VaultRepository.swift:147-156,381-405`, `GalleryViewModel.swift:78-91` | Medium | Likely (date sorts), speculative (name/type) | 1k: ~1-3 ms per page. 10k deep pages: ~5-20 ms (date sorts); name and type sorts possibly tens to 100+ ms | B2 `testDeepPage10k_*`, `testScrollToEnd10k` |
| 13 | P13 | Import review previews are decoded on main and keep full 720-px bitmaps | `ImportViewModel.swift:114`, `ImportPreviewView.swift:242-251,776-786` | Medium | Likely | ~1.1-1.5 MB per candidate, so ~280-375 MB after a 250-item import | B10 `testReviewPreviewMemory60` |
| 14 | P14 | PBKDF2 is a pure-Swift loop that re-keys HMAC on every iteration | `PBKDF2.swift:21-36` | Medium | Likely | Same at any library size: ~0.15-0.25 s (A15+) or ~0.3-0.4 s (A12) per derivation, against ~15-40 ms with CommonCrypto | B4 `testPBKDF2_210k`, `testPasscodeUnlockProductionPolicy` |
| 15 | P15 | Storage analysis makes 2N sequential actor round trips, sorts on main and cannot be cancelled | `StorageAnalysisService.swift:37-89` | Medium | Likely | 1k: ~0.1-0.3 s. 10k: ~0.6-2 s of spinner plus ~0.1-0.4 s of main-thread block | B12 `testAnalyze1k/5k`, `testOverlappingAnalysesAreNotDuplicated` |
| 16 | P16 | Thumbnail requests are never cancelled and run in FIFO order, with no prefetch | `ThumbnailService.swift:17-48` | Medium | Certain | A fling through 1k items queues ~1k decrypts; tiles visible after the fling wait ~0.3-1 s | B1 `testCancelledRequestsDoNotDecrypt`, B3 `testScrollCost1k` |
| 17 | P17 | Import encryption awaits a main-actor hop after every 1 MiB chunk, and each tick re-renders the import screen | `ChunkedEncryptionService.swift:159-161`, `ImportViewModel.swift:212-214` | Medium | Certain (count), speculative (time) | Same at any library size: ceil(MiB) + 2 hops per item (130 for 128 MiB); 0-50% slower encryption while main renders | B9 `testImport128MiBWithProgress`, `testImport128MiBWithBusyMain` |
| 18 | P18 | Export decrypts every item before showing anything: sequentially, under the gate, without progress | `MediaExportService.swift:71-136`, `VaultRepository.swift:126-137` | Medium | Likely | Depends on selection size: 20 × 300 MB ≈ 10-30 s before the sheet. Save to Photos writes everything twice | B13 `testPrepareForSharing8x16MiB`, B11 `testExportItems1000of10k` |
| 19 | P19 | The Trash tab's first load waits for the purge, which waits for the gate | `TrashScreen.swift:60-68`, `TrashService.swift:109-169` | Medium | Certain | "Trash is empty" flashes on every first visit, and stays for the whole length of a concurrent export or large Trash operation | B11 `testPurgeNothingExpired10k`, `testPurgeExpired1k`, `testTrashLoadWhileGateHeld` |
| 20 | P20 | Every ephemeral decrypted temp file is fsynced | `ChunkedEncryptionService.swift:222` | Medium | Likely | Same at any library size: ~0.1-0.5 s of extra wait per 500 MB of video, share or save | B7 `testTemporaryDecryptedFile128MiB`, B13 |
| 21 | P21 | Duplicates are detected only after a full encrypt, write and fsync | `MediaImportService.swift:108-130` | Medium | Certain | Each duplicate costs a full encrypt and write (a 2 GB video ≈ 2-4 s) | B9 `testReimportDuplicate64MiB` |
| 22 | P22 | Picker completion runs synchronous PhotoKit queries on main, freezing the picker | `PhotoLibraryPicker.swift:102-158` | Medium | Likely | 250 results: ~0.5-2.5 s freeze | Optional `PhotoEligibilityPerformanceTests` (needs a Photos grant) |
| 23 | P23 | Bulk Favorite makes one fetch and one save per item | `GalleryBrowser.swift:341-348`, `VaultRepository.swift:262-274` | Medium | Certain (saves) | 500 items: 500 saves ≈ 0.5-1.5 s on main | B11 `testBulkFavorite500of10k` |
| 24 | P24 | The selected photo waits behind a neighbour decode that cannot be cancelled, and paging back and forth decrypts again | `ViewerPhotoLoader.swift:62-147` | Medium | Likely | 48 MP: up to ~0.3-0.5 s of extra wait; each return costs a full decrypt and decode | B6 `testSelectedPhotoBehindNeighbour48MP`, `testBackAndForthDecryptCount` |
| 25 | P25 | The signature transitions share the main thread with heavy work | `RootView.swift:165-174,243-271`, `MediaViewer.swift:114-118,440-468` | Medium | Speculative | Gets worse with loaded depth: dropped frames in the 0.32-0.42 s animations | B3, B6 partly; frame pacing needs a device |
| 26 | P26 | A GeometryReader in every tile re-evaluates on every scroll frame | `GalleryGridView.swift:63,110-137` | Medium | Likely | ~0.15-0.4 ms per frame on iPhone, ~0.5-1.5 ms on iPad, at any library size | B3 `testScrollCost1k` (with and without tile frames) |
| 27 | P27 | The grid re-diffs the whole loaded array; items are reassigned even when unchanged and are live models | `GalleryGridView.swift:46,102`, `GalleryViewModel.swift:7,66,83` | Medium (deep scroll) | Likely / speculative | 1k loaded: ~1-2 ms per change; 10k loaded: ~5-20 ms per change and ~10-20 MB of models | B3 `testPageAppendCost1k/5k/10k` (diagnostic) |
| 28 | P29 | Import saves each item on main while live whole-table queries may re-fetch after every save | `VaultRepository.swift:44-75`, `AlbumsScreen.swift:9` | Medium | Speculative | Only if hidden tabs update: ~30-150 ms per imported item at 10k; otherwise the 1-5 ms SQLite commit per item | B5 `testImportInsertsWithAlbumsVisible`, B9 save counts |
| 29 | P28 | Tiles have a heavy view tree and rebuild their strings on every render; closure inputs defeat diffing | `GalleryGridView.swift:47-85`, `MediaThumbnailView.swift:24-58` | Low | Likely / speculative | ~0.1-0.5 ms per tile creation; ~0.3-1 ms per selection tap or keystroke | B3 `testScrollCost1k`, `testSelectionToggleCost` (diagnostic) |
| 30 | P30 | Every Trash operation and viewer delete flushes the whole thumbnail cache, but a purge evicts nothing | `TrashScreen.swift:286-295`, `MediaViewer.swift:784` | Low | Certain | ~20-90 visible tiles decrypt and decode again; live Trash tiles lose the zoom and the poster | B1 `testTrashOperationEvictions` |
| 31 | P31 | One serial crypto executor for the whole app, copies in every chunk, and a growing `Data` in in-memory decrypt | `ChunkedEncryptionService.swift:27,140-164,231-281` | Low | Likely | Same at any library size: ~5-10% of crypto throughput; small decrypts wait 5-10 ms behind large ones | B8 all |
| 32 | P32 | Every lock tears the vault UI down and every unlock rebuilds it cold | `RootView.swift:112-116,151-153` | Low (own cost) | Certain (mechanism) | Its own rebuild cost is ~10-50 ms per unlock; it multiplies the cold costs of P01-P05 | B4 `testUnlockToUnlocked10k` |
| 33 | P33 | A short `.inactive` cancels an in-progress video decrypt | `SecureMediaPage.swift:177-189,260-268` | Low | Certain (mechanism) | With a non-zero auto-lock or no passcode: the decrypt restarts from zero after each Control Center glance | B7 `testInactiveScenePhaseRestartsDecrypt` |
| 34 | P34 | Tiles and covers show a placeholder for at least one frame even when the image is cached | `MediaThumbnailView.swift:12,52-54`, `AlbumsScreen.swift:466,496-502` | Low | Likely | At least 1 frame per tile creation | B1 `testFirstFrameUsesCachedImage` |
| 35 | P35 | Viewer extras: showing the chrome rebuilds the filmstrip, one observed dictionary, a viewer-wide query, formatting on every render | `MediaViewer.swift:42,227-245`, `ViewerPhotoLoader.swift:37-38` | Low | Likely | Small per event, multiplied by P06 | Covered by B6 |
| 36 | P36 | The scrubber issues an exact seek per drag event; the frame strip uses a second asset and loads frames one by one | `ViewerScrubber.swift:137-147`, `ViewerVideoPlayback.swift:146-191` | Low | Likely | Decoder churn while scrubbing; 0.1-0.5 s of decoder work at playback start | B7 (optional frame-strip test) |
| 37 | P37 | Import keeps incoming copies until the batch ends, stores thumbnails through plaintext temp files, and deletes files on main | `MediaImportService.swift:102,138-150` | Low | Certain | ~0.2-1 ms and ~200 KB of extra I/O per item; disk use can reach 2× the plaintext; 5-50 ms of main-thread unlinks per 250 items | B9 `testImport200SmallItemsWithThumbnails`, `testIncomingReleasedPerItem` |
| 38 | P38 | Free-space is queried for every imported item and every temp file | `MediaImportService.swift:238-244`, `SecureFileStorageService.swift:135-145` | Low | Speculative | Unknown, 0.5-40 ms per call on a device | B9 (counts only; cost needs a device) |
| 39 | P39 | Thumbnail generation blocks cooperative threads; the 48 MP HEIC peak is unknown; each source is opened twice | `ThumbnailGenerator.swift:19-47` | Low (medium once preparation runs in parallel) | Speculative | 100-500 ms per item; up to ~195 MB transient if a 48 MP image decodes in full | B10 `testThumbnailGeneration12MP/48MP` |
| 40 | P40 | Bulk file moves and deletes make one actor hop and ~5 syscalls per item while holding the gate | `TrashService.swift:36-39,73-76`, `SecureFileStorageService.swift:162-181` | Low | Likely | 1k items: ~0.2-0.4 s; 10k items: ~2-4 s, all while holding the gate | B11 `testMoveToTrash1000`, `testEmptyTrash1k` |
| 41 | P41 | Directory listings build NSURLs with default prefetched properties | `SecureFileStorageService.swift:189-200,224-236` | Low | Speculative (gain) | Listing takes ~20-100 ms per unlock at 10k | B4 `testListIdentifiers10k` |
| 42 | P42 | Bootstrap runs on main, gate start-up runs serially, and the system launch screen is white in Light Mode | `AppModel.swift:21-35`, `project.pbxproj:409,442` | Low | Likely | ~20-80 ms on main at launch; a one-off migration takes longer | B14 `testColdLaunchToGate`, B4 `testBootstrapOpen10k` |
| 43 | P43 | Small fixed overheads: thumbnail decrypt set-up, Keychain calls, settings fetches, re-sorting, shield churn | Several (3.2) | Low | Certain | Each well under 1 ms, but the thumbnail set-up is paid thousands of times while scrolling | B8 `test1000SmallDecrypts` |
| 44 | P44 | Reset deletes rows one by one; existence checks load whole objects | `VaultLockCoordinator.swift:432-441` | Low | Likely | Reset at 10k: ~1-3 s, and resets are rare | Not benchmarked (reset writes the real marker until seam S5 lands) |
| 45 | P45 | iPad windows share one session and cache, and opening a window deletes another window's import files | `RootView.swift:102-111`, `MediaImportService.swift:229-236` | Medium (correctness) | Certain | Import failures; memory use multiplies per window | Behaviour test only |
| 46 | P46 | `Assets.car` is 30 MB because the icons are SVG | `AppIcon.appiconset` | Low | Certain | Download and install size only | CI byte-count step |

### 3.2 Evidence per issue

**P01. Thumbnails are decoded on the main thread at first draw.**
*Merges:* PERF-GT-01, VIEW-09, SHELL-06, the import auditor's missed issue 1, completeness X7.

- **Code:** `ThumbnailService.swift:31-33` runs `let image = await Task.detached(priority: .utility) { UIImage(data: data) }.value`.
- **Why it costs:** `UIImage(data:)` parses only the header. The ImageIO-backed image is decoded when Core Animation first commits it, on the main thread. That is why `preparingForDisplay()` and `byPreparingThumbnail(ofSize:)` exist (iOS 15). By contrast, `ViewerPhotoLoader.swift:132-145` forces its decode off main with `kCGImageSourceShouldCacheImmediately`.
- **Where it applies:** gallery tiles (`MediaThumbnailView.swift:61-65`), album covers (`AlbumsScreen.swift:485-502`; a 1.56 MB decode for a 40-pt cover), filmstrip tiles and viewer placeholders.
- **Estimates:** a 720×540 decode costs ~1-3 ms on A15 or newer (likely). An iPhone fling at 5,000-8,000 pt/s reveals 125-200 tiles per second. The first screen after unlock lands during the 0.32-0.42 s unlock animations (P25).

**P02. The thumbnail cache is too small for full-size bitmaps.**
*Merges:* PERF-GT-02, PERF-GT-11 (the part confirmed as certain), VIEW-10, the cache part of SEC-PERF-17, X7, the gallery auditor's re-appearance issue.

- **Code:** thumbnails are stored at up to 720 px (`ThumbnailGenerator.swift:14,27`) and cached at full size with cost w×h×4.
- **Cache capacity:**

  | Thumbnail shape | Bytes per entry | Entries in 67,108,864 B |
  |---|---|---|
  | 4:3 (720×540) | 1,555,200 | 43 |
  | 16:9 | 1,166,400 | 57 |
  | Square | 2,073,600 | 32 |

  The 500-item count limit never applies.
- **What tiles actually need:** an iPhone 16 Pro tile at Comfortable is 114 pt × 3 = 342 px, and filling it with a 4:3 image needs 456×342×4 = 623,808 B. The stored thumbnail is 2.5× larger than needed at that size, 4.6× at Compact, 6.6× on iPhone SE and 6.7× on a 13-inch iPad. At accessibility sizes the single 1,062-px column upscales it.
- **Viewer effects (certain):** every viewer path that reads `cachedImage(for:)` degrades after an eviction:
  - the opening zoom (`MediaViewer.swift:443-452`) fades instead;
  - the closing image for videos (`:557`);
  - the photo placeholder (`SecureMediaPage.swift:101`);
  - the video poster (`:153`).

  On an iPad the first screen alone exceeds the cache.
- **Pinned memory:** each realized tile pins its image in `@State` (`MediaThumbnailView.swift:12`), outside the cache bound: about 140 MB (iPad Comfortable) or 240 MB (iPad Compact) once displayed. Unbounded growth from off-screen state that is kept alive is speculative.
- **Re-appearance:** returning to a tab re-runs every visible tile's `.task`, which decrypts evicted thumbnails again and decodes them again on main.

**P03. Unlock waits for maintenance.**
*Merges:* PERS-01, SHELL-01, SEC-PERF-10, the storage auditor's missed issue 1 (reconcile part), the persistence auditor's cold-path issue, the shell auditor's missed issue 1.

- **Code:** `AppDependencies.swift:96-99` runs `reconcile()` and then `purgeExpiredItems()`. Every unlock path awaits both before `state = .unlocked`:
  - passcode unlock: `unlock` at `VaultLockCoordinator.swift:175-181`;
  - Face ID: `:188-194`;
  - no-passcode launch: `:79-82`;
  - no-passcode resume: `:153-158`.
- **Reconcile:** it runs on main inside the gate closure. `StorageReconciliationService.swift:28` fetches every row and every column, makes 5 passes (about 4N getter calls), and then lists 3 directories one after another (an NSURL per entry).
- **Purge:** fetches every trashed row and filters in Swift. If anything has expired, it fetches the whole table again.
- **Waiting behind the gate:** maintenance also waits behind any gate holder that `lock()` does not stop. Those are `deleteAlbum(.moveMediaToTrash)`, `emptyTrash`, and `saveToPhotos`, whose `performChanges` cannot be cancelled.
- **Who pays:** for Face ID and no-passcode opens this is most of the wait after authentication. In no-passcode mode the Auto-Lock picker is hidden, so `autoLockSeconds` stays 0 and maintenance runs on every return to the app. At 10k items the directory listing (~20-100 ms) is the smaller part; the main-thread fetch dominates.

**P04. Search scans the whole scope on main.**
*Merges:* PERF-GT-04, PERS-05, the search part of VIEW-18.

- **Code:** `VaultRepository.swift:158-175` fetches the whole scope with no limit. Per item it checks the filename, the album name and the tags, makes two `DateFormatter.string(from:)` calls and compares the year, then slices out the page.
- **Repeats:** `loadNextIfNeeded` (`GalleryViewModel.swift:82`) and `refreshLoadedItems` (`:64`) repeat the whole scan for every page and every refresh, including each viewer close.
- **Extra costs:** the unlimited scope fetch also sorts in SQLite, through the collation for the Name and Type sorts (P12). Once the 250 ms debounce fires, the synchronous search cannot be cancelled.
- README limitation 9 already admits this.

**P05. The Albums tab loads everything for three counts.**
*Merges:* PERS-03, PERS-04 (corrected), PERF-GT-21 (corrected), SHELL-02, SHELL-05 (corrected), X3, the persistence auditor's Observation issue.

- **Code:** `AlbumsScreen.swift:9` declares `@Query(filter: #Predicate<VaultMedia> { $0.trashedAt == nil }) private var activeMedia`. It is used only for `activeMedia.count` and two `lazy.filter` counts (`:110-112`, `:233-236`).
- **Observation cost:** reading `isFavorite` and `importedAt` inside `body` registers an Observation dependency per element (about 2N tracked reads per render). Any change to those properties on any item then invalidates the screen.
- **Memory and lifetime:** the tab stays alive until the next lock, so the fetch is paid cold on the first Albums visit after every unlock and ~10 MB of models stay resident.
- **Album rows:** each row's `activeMediaCount` (`VaultAlbum.swift:31-33`) builds the whole relationship array once per list rebuild. `AlbumCover` re-evaluates only when its own tracked dependencies change, not on every AlbumsScreen render (corrected).
- **Fix together:** if the `activeMedia` query is removed but the rows are left alone, each row's first `album.media` read fetches that album's members, which moves the cost instead of removing it.
- **Confidence split:** re-fetching while the screen is visible is certain. Re-fetching after every save while the tab is hidden is speculative (P29).

**P06. The viewer does O(n) work in `body`.**
*Merges:* VIEW-01, VIEW-02, VIEW-03, VIEW-13 (as a measurement item), the viewer part of PERF-GT-14, X10, the gallery auditor's viewer-drag issue.

- **The scans:**
  - `selectedMedia` and `selectedIndex` are linear scans (`MediaViewer.swift:89-95`).
  - `photoRequests` (`:97-102`) is evaluated in `body` through `.onChange(of:)` (`:124`).
  - The pager builds `Array(items.enumerated())` (`:262`), and `ForEach` reads `\.element.id` for all n items.
  - `ViewerFilmstrip.swift:45-47` and `ViewerChrome.swift:137-139` scan again.

  That is about n + 5i reads of the `@Model` `id` per evaluation (i = selected index). Each read goes through the macro getter (registrar access plus backing data), and reads made in `body` register Observation dependencies.
- **What triggers an evaluation:**
  - **The dismiss drag:** every drag event writes the `@State liftTranslation` (`:351-371`). That re-runs the whole body plus the children that take closure inputs (`ViewerChrome`, the pages) on every touch event, at 60-120 Hz.
  - **Horizontal swipes:** `dismissDragIsActive` is read in `body` (`:137`) and flips twice per swipe.
  - **Page changes:** a page change writes the presenter's `hiddenMediaID` (`GalleryBrowser.swift:139-151`). That re-renders the presenter and the grid, re-creates `MediaViewer` (whose `State(initialValue:)` allocates a loader and a playback object only to discard them), and runs another full body.
- **Measurement item:** VIEW-13, the cost of resolving the explicit `.tag`, is unproven.
- **Estimates:** the cost per read is unmeasured (0.2-2 µs). Typical sessions, with 400 or fewer items loaded, stay at a few ms or less.

**P07. Video waits for a full decrypt.**
*Merges:* VIEW-05, SEC-PERF-02, VIEW-12 (raised to likely), part of VIEW-17.

- **Code:**
  - `SecureMediaPage.swift:214-231` awaits `storage.temporaryDecryptedFile` before it creates the `AVQueuePlayer`.
  - `temporaryDecryptedFile` (`SecureFileStorageService.swift:127-160`) decrypts every chunk in sequence and then calls `output.synchronize()` (`ChunkedEncryptionService.swift:222`).
  - `progress` is nil, so the UI can show only an indeterminate spinner.
- **Repeats:**
  - `.task(id: PlaybackLifecycle(isActive, scenePhase))` cancels an in-flight decrypt as soon as the page stops being active. The partial file is deleted and the next activation starts from byte 0.
  - `.onDisappear { cleanup() }` (`:193`) probably fires when a `.page` TabView page scrolls off screen. That deletes the lease, loses the resume position and regenerates the scrubber frames.
- **Format:** the QFRAME01 format authenticates each chunk independently, so random access is possible (P07 fix, Phase 7).

**P08. Single-item actions fetch the whole table.**
*Merges:* PERS-02, the fetch part of PERF-GT-13, the viewer auditor's missed issue 1, the storage auditor's missed issue 1.

- **Code:** `TrashService.swift:171-174` runs `try modelContext.fetch(FetchDescriptor<VaultMedia>()).filter { ids.contains($0.id) }`. It is used by `moveToTrash` (`:31`), `restore` (`:68`) and `permanentlyDelete` (`:110`). `VaultRepository.swift:229-230` does the same for `moveMedia`.
- **Restore** also looks up each item's previous album with `albums.first(where:)` (`:82-87`), which is O(T×A).
- **Callers:** viewer single-item actions (`MediaViewer.swift:712,753,768,783`), the gallery selection bar (`GalleryBrowser.swift:427,482`) and Trash (`TrashScreen.swift:269,276`). All of it runs on main inside gate closures.
- **Contrast:** `exportItems` already fetches by ID predicate (P18 covers its per-ID loop).

**P09. Preparation runs serially.**
*Merges:* IMP-2 and the import auditor's double-parse issue.

- **Code:** `ImportViewModel.swift:72-127` runs `for selection in selections { try await selection.loadProtectedFile(); ...metadata(...); ...jpegThumbnail(... 720) }`, and `candidates = prepared` happens only at `:133`.
- **Why a fan-out alone would not help:** `MediaMetadataService` and `ThumbnailGenerator` are single actor instances (`AppDependencies.swift:44-45`), so their work would still serialize.
- **No overlap:** the picker transfer (IPC, plus an iCloud download for optimized originals) never overlaps the previous item's decode.
- **Per-photo estimate:** transfer 30-200 ms, metadata 1-5 ms, thumbnail 30-80 ms at 12 MP or 100-300 ms at 48 MP. The preparing screen shows no count.
- **Double parse:** each file is opened twice, through separate `AVURLAsset` or `CGImageSource` instances for metadata and for the thumbnail.

**P10. The viewer holds large bitmaps.**
*Merges:* VIEW-04 (corrected), VIEW-14 (folded in), the storage auditor's viewer-memory issue.

- **Code:** `maximumPhotoPixelSize = 4_096` (`ViewerPhotoLoader.swift:7`). The window keeps up to three images (`:62-75`), each decoded with `ShouldCacheImmediately`, so the bitmaps stay resident.
- **Resident memory (certain):** 3 × 48.8 MB for 12-MP sources (4032×3024×4), or 3 × 50.3 MB for 48-MP sources downsampled to 4096×3072×4. That is 146-151 MB.
- **What is actually needed:** neighbours and the unzoomed page need only screen resolution. On iPhone 16 Pro (1206×2622 px) a fitted 4:3 photo is about 4.4 MB, and a 2622-px rendition about 20.6 MB.
- **While paging:** about 200-250 MB, plus the encoded file and an unknown decoder intermediate for 48-MP HEIC (195 MB if it decodes in full; unverified).
- **Memory warnings:** the app has no handler anywhere.
- **Severity:** this is not a demonstrated jetsam. It is real memory pressure on 3-4 GB devices, and more serious on the 2 GB iPad (6th generation) that iPadOS 17 still supports.
- **First commit:** each newly decoded bitmap also pays a first Core Animation commit when its page first renders.

**P11. Refresh re-fetches everything loaded.**
*Merges:* PERF-GT-07, PERS-10, VIEW-18, the import auditor's refresh-after-import issue.

- **Code:** `GalleryViewModel.swift:64` runs `repository.fetchMedia(query: query, offset: 0, limit: max(items.count, pageSize))`, then always reassigns `items`, then calls `selectedIDs.formIntersection`.
- **Callers:**
  - `.task` on every appearance (`GalleryBrowser.swift:98-108`);
  - import dismissal (`:118-121`);
  - viewer dismissal (`:139-143`);
  - move (`:429`) and trash (`:484`);
  - `TrashScreen.swift:60-73,294`.
- **Cost:** exactly loaded + 1 rows per refresh, plus a full grid re-diff. With a search active it becomes a full search (P04).
- **Caveat for a fix:** the Recently Added cutoff moves with time, so "nothing was saved" does not mean "nothing changed".

**P12. Offset paging.**
*Merges:* PERF-GT-05, PERF-GT-08, PERS-15 (corrected).

- **Code:** `descriptor.fetchOffset = offset; descriptor.fetchLimit = limit + 1` (`VaultRepository.swift:152-154`).
- **No index:** without `#Index` (iOS 18 only), every page scans the table and keeps a top-N sort of offset + 81 rows. Album galleries can probably use the foreign-key index.
- **No look-ahead:** `GalleryViewModel.swift:79` requires `currentItem.id == items.last?.id`. The last tile is about one row from the content end, so a fast fling has roughly 15 ms before it hits the end. The spinner never renders.
- **Collation:** string sort descriptors (`\.originalFilename`, `\.storageIdentifier`, and `\.mediaTypeRawValue` as Type's primary key) default to `.localizedStandard`. Core Data's SQLite store evaluates that through a custom collation that cannot use an index, and the Type sort sends nearly every comparison through it.
- **Confidence:** likely for date sorts; the name and type magnitudes are speculative.

**P13. Import review previews are large and decoded on main.**
*Merges:* IMP-6 (corrected).

- **Code:** `previewImage: thumbnailData.flatMap { UIImage(data: $0) }` (`ImportViewModel.swift:114`) creates a lazily decoded image.
- **Waste:** the 104-160 pt tiles (312-480 px at 3×; `ImportPreviewView.swift:776-786`) draw from 720-px images, decoded on main at first render.
- **During the import:** the importing grid auto-scrolls through every tile (`:242-251`, `:973`), so every preview is decoded during the import while the crypto loop waits on main (P17).
- **Lifetime:** `candidates` keeps the images until the summary.

**P14. PBKDF2 is slow.**
*Merges:* SEC-PERF-01, SHELL-03.

- **Code:** each iteration runs `previous = Data(HMAC<SHA256>.authenticationCode(for: previous, using: passwordKey))` plus 32 XORs through `Data` subscripts (`PBKDF2.swift:29-34`).
- **Why it costs:**
  - HMAC re-pads the key every iteration: 4 SHA-256 compressions instead of 2.
  - Each iteration allocates a 32-byte `Data` on the heap (more than Data's 14-byte inline storage).
  - CI builds this at `-Onone`.
- **Call counts:** one per unlock attempt (`AuthenticationService.swift:199` → `:387`); two per passcode change (`:274`, `:281`); one each for create, add, remove and normal reset.
- **User-visible:** the keypad is disabled while it runs, and the wrong-code shake starts only after `unlock` returns.
- **A drop-in replacement exists:** the algorithm is standard RFC 8018 (block index appended big-endian), so `CCKeyDerivationPBKDF` produces identical output (vectors in 5.2). Cost does not depend on library size.

**P15. Storage analysis.**
*Merges:* PERS-06, SEC-PERF-11, SHELL-04, the shell auditor's missed issue 3.

- **Code:** `StorageAnalysisService.swift:45-64` awaits `storage.fileByteCount(...)` once or twice per item. Each call is a main ↔ storage-actor round trip running `attributesOfItem`.
- **Main-thread sort:** `:66-69` filters and sorts every model on main with a getter comparator, about N log N calls.
- **Repeats:** `.task` (`StorageManagementView.swift:59`) runs on every appearance and `.refreshable` (`:31`) on pull. The loop never checks for cancellation, so tab switches start overlapping passes.

**P16. Thumbnail requests cannot be cancelled.**
*Merges:* PERF-GT-03, SEC-PERF-17, PERF-GT-10.

- **Code:** `ThumbnailService.swift:23` creates an unstructured `Task`, and `:46` runs `await task.value`. A waiter's cancellation never reaches the task. The checks at `:30` and `:34` see only cancellation that comes from `clearCache()`.
- **Effect:** a fling through 1k items queues about 1k decrypts (0.3-1 ms each, serialized on the encryption actor). They complete in FIFO order, so the tiles visible when the fling stops wait behind them.
- **No prefetch:** nothing loads beyond `LazyVGrid`'s small margin.

**P17. Import progress waits on the main thread.**
*Merges:* IMP-1 (corrected), SEC-PERF-04 (corrected), X2, IMP-7 (corrected), the storage auditor's missed issue 2.

- **The awaited chain:**
  - `ChunkedEncryptionService.swift:159-161` runs `if let progress { await progress(...) }` inside the chunk loop.
  - `MediaImportService.swift:118-124` forwards every fraction and awaits it.
  - `ImportViewModel.swift:212-214` runs `await MainActor.run { self?.progress = value }`.

  So the next chunk is not read until main has applied the value.
- **Fixed hops:** four more main round trips per item overlap no crypto at all: the start tick (`:109`), `containsFingerprint` (`:126`), insert plus save (`:173`) and the end tick (`:209`).
- **Re-rendering:** each assignment re-evaluates the whole `ImportPreviewView` (`progress` is read in `body` at `206`, `217-221`, `229`, `242`). `@Observable` notifies even for equal values, and the end tick of item i equals the start tick of item i+1. Most sealing cells are probably skipped because their inputs do not change.
- **Estimate:** the lost time is about Σ max(0, R − C) over chunks plus the fixed hops, where R is the main-thread work per tick (0.5-3 ms, estimated) and C is about 1-2.5 ms per MiB. Photos are hit as hard as videos: a 3 MB photo makes about 7 hops.

**P18. Export.**
*Merges:* IMP-12, IMP-15, PERS-13, VIEW-11, the storage auditor's bulk-share issue, the export part of IMP-10.

- **Share:** `MediaExportService.swift:83-104` calls `temporaryDecryptedFile` for every item before it returns the lease. Each call queries capacity (per item, not in aggregate), decrypts fully and fsyncs (P20).
- **Save to Photos** (`:106-136`): decrypts everything, then makes one `performChanges` with `addResource(with:fileURL:options: nil)`. Without options, `shouldMoveFile` is false, so Photos copies every file.
- **Gate and lookups:**
  - the gate is held throughout;
  - `exportItems` (`VaultRepository.swift:126-137`) runs one fetch per ID, so 1,000 IDs take ~0.2-1 s on main;
  - viewer Share and Save (`MediaViewer.swift:719-746`) decrypt again a video that the page already holds as a lease.
- **Errors:** running out of disk mid-export shows "This item could not be verified or opened." (see 3.5).

**P19. The Trash tab waits for the purge.**
*Merges:* PERF-GT-19 (corrected), PERS-12 (corrected), X4, the persistence auditor's false-error issue, PERS-07 (corrected).

- **Code:** `TrashScreen.swift:60-68` runs `.task { _ = try await dependencies.trashService.purgeExpiredItems(); ...; await viewModel.refreshLoadedItems() }`. The purge takes the FIFO gate. Until it returns, the list is empty and not loading, so the screen shows "Trash is empty".
- **Who can hold the gate:** gate holders that can run while Trash is reachable are a gallery Share or Save to Photos, or a large album delete or Trash operation. An import cannot, because its sheet blocks the tab bar (the original claim was corrected).
- **False error:** leaving the tab while the purge waits cancels it. The resulting `CancellationError` is mapped to the generic file-operation alert, and that purge is skipped.
- **Purge cost:** every visit fetches all trashed rows (`TrashService.swift:158-164`); if anything has expired, it also fetches the whole table.

**P20. Ephemeral temp files are fsynced.**
*Merges:* SEC-PERF-05, the interim part of VIEW-05.

- **Code:** `decryptFile` calls `try output.synchronize()` (`ChunkedEncryptionService.swift:222`). Its output is only ever a temp file: video, Share or Save to Photos. Temp files are deleted on cleanup, on lock and at launch, and AVPlayer and PhotoKit read them through the page cache.
- **Keep:** the encrypt-side fsync (`:167`) must stay, for durability before the metadata insert.
- **Not included:** dropping the capacity check. Without it, a full disk would surface as `corruptedFile`.

**P21. Duplicates are found too late.**
*Merges:* IMP-4, SEC-PERF-16.

- **Code:** `store` (`MediaImportService.swift:115`) runs before `containsFingerprint` (`:126`), because the fingerprint exists only after `encryptFile` (`ChunkedEncryptionService.swift:166-178`).
- **Side effect:** the free-space check (`:108`) runs first, so a duplicate on a nearly full disk counts as Failed even though it needs no space.
- **Note:** `containsFingerprint` also matches trashed rows.

**P22. Picker completion freezes the picker.**
*Merges:* IMP-5, X9.

- **Code:** for every result, `picker(_:didFinishPicking:)` runs `PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)` (`PhotoLibraryPicker.swift:146-149`) and `PHAssetResource.assetResources(for:)` (`PhotoLibraryService.swift:39`), on main, before `completion` (`:130`). The picker stays frozen on screen until all of them finish.
- **Cost:** ~2-8 ms per item. None of this runs when access is denied.

**P23. Bulk Favorite saves per item.**
*Merges:* PERS-08, PERF-GT-13, X5.

- **Code:** `selectedItems.forEach { galleryViewModel.setFavorite(mediaID: $0.id, isFavorite: true) }` (`GalleryBrowser.swift:341-345`). Each call is an indexed fetch, an album bump and `modelContext.save()` (`VaultRepository.swift:262-274`). `selectedItems` (`:408-410`) scans every loaded item.
- **Cost:** N SQLite transactions and N `didSave` notifications. The view updates probably coalesce into one render, because everything runs synchronously in one action.

**P24. Viewer photo scheduling.**
*Merges:* VIEW-06, the viewer auditor's back-and-forth issue.

- **Code:** there is one load slot, and the comment at `ViewerPhotoLoader.swift:91` says "A cancelled load keeps its slot until it finishes so decodes never overlap". The detached decode (`:132-145`) ignores cancellation.
- **When it hurts:** the selected photo waits only when the cancelled load is already decoding; a decrypt cancels within a chunk.
- **No retention:** `prepare` (`:62-75`) drops everything outside [selected, next, previous]. A→B→C→B→A therefore decrypts and decodes A twice.
- **Tests:** existing tests encode this policy (one decrypt at a time; the cancelled load keeps its slot).

**P25. Transitions compete for the main thread.**
*Merges:* SHELL-08 and the viewer auditor's opening-flight issue.

- **Unlock:** the MainTabView insertion (`RootView.swift:165-174`), the iris flourish (`:243-271`) and the UnlockView fade run while `loadInitial` does a synchronous fetch with no index and the tiles decode thumbnails on main (P01).
- **Viewer opening:** `ViewerZoomFlyer` animates frame, position, clip shape and opacity through SwiftUI on main (`ViewerZoomTransition.swift:150-170`). During those 0.36 s:
  - `onAppear` publishes `hiddenMediaID`, which triggers the presenter re-render and a full O(n) body (P06);
  - the selected photo's decode finishes and builds a `ZoomablePhotoView` behind the flyer (the first commit of a ~50 MB bitmap);
  - at 0.12 s the chrome mounts the filmstrip, whose uncached tiles decode on main.
- **Effect:** at 120 Hz, any main-thread block longer than about 8 ms skips frames. The magnitude is speculative, and frame pacing can only be verified on a device.

**P26. A geometry reader in every tile.**
*Merges:* PERF-GT-09 (corrected).

- **Code:** every tile has `.background { GeometryReader { proxy in let tileFrame = proxy.frame(in: .global) ... .onChange(of: tileFrame) { tileFrames.set(...) } } }` (`GalleryGridView.swift:110-121`).
- **Why it costs:** a tile's global frame changes on every scroll frame, so every realized tile re-runs the reader and its `onChange` on every frame. The frames are read only when the viewer opens or closes (`MediaViewer.swift:445`, `:561`).
- **Estimate:** 5-15 µs per tile per frame.

**P27. Whole-array diffs and live models.**
*Merges:* PERF-GT-06, PERF-GT-20.

- **Code:** `ForEach(viewModel.items)` (`GalleryGridView.swift:46`) builds its identities from the `@Model` `id` getter.
- **When it diffs:** `items` is reassigned on every refresh even when the IDs are identical (`GalleryViewModel.swift:66`), and appended per page (`:83`). The count change also runs an animation transaction (`:102`).
- **Models:** the items are fully materialized models without `propertiesToFetch`, about 1-2 KB each (speculative). This matters only for users who scroll deep (10k loaded = 125 pages).

**P28. Heavy tiles, and closures that defeat diffing.**
*Merges:* PERF-GT-14 (grid part, corrected), PERF-GT-15, PERF-GT-17.

- **Grid tile:** a Button, a long press, a context menu, a content shape, 2 accessibility actions, a paging `.task(id:)` (a second Task per tile) and a GeometryReader (`GalleryGridView.swift:47-85`).
- **Thumbnail view:** `ViewThatFits`, `@ScaledMetric`, its own `.task`, and an `accessibilitySummary` rebuilt on every body run, with a date format and an album relationship read (`MediaThumbnailView.swift:24-58`, `VaultMedia.swift:69-79`).
- **Closure inputs:** `GalleryGridView` takes closures (`open`, `emptyAction`), so SwiftUI can never skip it. Any change in `GalleryBrowserContent` re-runs the grid body and the realized row closures: selection taps, keystrokes, the `@Query` albums re-fetch, sheet flags, `hiddenMediaID`. `MediaThumbnailView`'s own body is still skipped unless its inputs change.
- **Main hops:** the thumbnail pipeline makes three or more main-actor hops per image.

**P29. Per-item import saves, possibly amplified.**
*Merges:* IMP-3 (corrected), PERS-09 (corrected).

- **Certain:** each item does a main-actor insert and `modelContext.save()` (`VaultRepository.swift:44-75`), plus `containsFingerprint` and `findAlbum`. Saves = imported + 2, and each is a synchronous SQLite transaction on main (~1-5 ms on device).
- **Speculative amplification:** it needs all of these to hold:
  - the Albums tab was visited in this unlocked session;
  - hidden tabs process `@Query` updates;
  - `@Query` re-fetches everything.
- **Always-present consumer:** `GalleryBrowserContent`, the presenter of the import sheet, owns `@Query` albums and settings. The `modifiedAt` bump of assigned inserts may re-render it.

**P30. Global cache flush.**
*Merges:* PERF-GT-16 (impact raised), PERS-16, X6, the gallery auditor's issues 4 and 5.

- **Code:** `dependencies.thumbnailService.clearCache()` runs after Restore, permanent delete and Empty Trash (`TrashScreen.swift:293`), and after a permanent delete in the viewer (`MediaViewer.swift:784`). `clearCache` bumps the generation, cancels every in-flight load and empties the cache (`ThumbnailService.swift:56-61`).
- **Effects:**
  - Restore deletes nothing, so its flush buys nothing.
  - The remaining Trash tiles keep their identity, so they keep showing their `@State` images while the viewer's `cachedImage` misses.
  - Cancelled loads return nil, and their tiles set `image = nil`.
  - The purge (`TrashService.swift:152-169`) never evicts thumbnails of purged items. That is a privacy gap at the reference level.

**P31. The crypto engine.**
*Merges:* SEC-PERF-03 (corrected), SEC-PERF-06 (corrected), SEC-PERF-07, VIEW-08, IMP-11.

- **One executor:** a single actor (`AppDependencies.swift:34`) runs every chunk. A small decrypt waits about 4 chunk turns (5-10 ms) behind a large job.
- **Copies:**
  - `readExactly` (`FileHandle+ExactRead.swift:4-15`) copies every read into a reserved buffer;
  - decrypt reads ciphertext and tag separately, and `SealedBox(nonce:ciphertext:tag:)` builds another combined copy;
  - encrypt writes ciphertext and tag with two calls;
  - `decryptData` (`:231-241`) appends into `Data()` without reserving, about 9 reallocations for 25 MiB.
- **What can be saved:** about one memcpy and one syscall per MiB on each path (5-10% of crypto time, likely), plus less allocation churn.
- **Limit:** import and export are sequential by design, so throughput would not scale with cores anyway.

**P32. Teardown on every lock.**
*Merges:* SHELL-07 (corrected), the persistence auditor's cold-path issue.

- **Code:** `MainTabView` exists only in `.unlocked` (`RootView.swift:151-153`), and the cache is cleared on any other state (`:112-116`).
- **When it recurs:** with the default Immediately, passcode mode locks on every background and on every inactive→active round trip (known issue). No-passcode mode does not lock on inactive→active, because the resume returns early (corrected).
- **Own cost:** only the SwiftUI rebuild, about 10-50 ms (estimate). Everything else is covered by P01-P05 and P14.

**P33. `scenePhase` restarts video decrypts.**
*Merges:* VIEW-07 (corrected).

- **Code:** `.task(id: PlaybackLifecycle(isActive, scenePhase))` (`SecureMediaPage.swift:177-189,260-268`) restarts on every scene-phase change. The cancellation reaches `decryptFile`, which deletes the partial file.
- **Scope:** with the default Immediately in passcode mode, an inactive→active round trip locks the vault instead. This issue therefore applies only with a non-zero auto-lock or in no-passcode mode.

**P34. Placeholder flash.**
*Merges:* PERF-GT-12, SHELL-15.

- **Code:** `@State private var image: UIImage?` starts nil (`MediaThumbnailView.swift:12`) and is filled only in `.task` (`:52-54`), which starts after the first commit.
- **Fix pattern already in the code:** `ViewerFilmstrip.swift:126` uses `image ?? thumbnailService.cachedImage(for: media)`. `AlbumCover` has the same problem (`AlbumsScreen.swift:466,496-502`).

**P35. Viewer extras.**
*Merges:* the viewer auditor's chrome issue, VIEW-21, VIEW-20 (corrected), VIEW-19.

- **Chrome:** `if controlsAreVisible { ViewerChrome(...) }` (`MediaViewer.swift:227-245`) unmounts the filmstrip on every hide. `FilmstripTile` keeps images only in `@State`, so showing the chrome reloads them (`ViewerFilmstrip.swift:118-143`) and decrypts evicted thumbnails again.
- **Loader:** `ViewerPhotoLoader.images` and `failures` are single observed dictionaries (`:37-38`), so every load invalidates every realized page.
- **Albums query:** `@Query(sort: \VaultAlbum.position) albums` (`MediaViewer.swift:42`) is used only by the Move sheet. The presenter has the same query, so moving it alone does not stop presenter-driven re-creation (that needs P06).
- **Formatting:** `viewerCaption` builds calendars and a `FormatStyle` on every render (`ViewerCaption.swift:11-58`).

**P36. Scrubbing.**
*Merges:* VIEW-15, VIEW-17.

- **Seeks:** each drag event calls `seek(to:toleranceBefore: .zero, toleranceAfter: .zero)` (`ViewerScrubber.swift:137-147` → `ViewerVideoPlayback.swift:183-191`), cancelling the previous seek.
- **Frame strip** (`:146-181`):
  - creates a second `AVURLAsset` and `AVAssetImageGenerator`;
  - awaits 12-17 `image(at:)` calls in sequence;
  - appends the frames one at a time, re-rendering the scrubber once per frame;
  - repeats on every return to a video (P07).
- **Keep as is:** the 30 Hz time observer only invalidates the scrubber (VIEW-16), which is correctly scoped.

**P37. Import file handling.**
*Merges:* IMP-8, IMP-9 (corrected), SEC-PERF-13, the import auditor's main-thread-unlink issue, the storage auditor's lease-cleanup issue.

- **Incoming copies:** `defer { sources.forEach { IncomingMediaFileStore.remove($0.temporaryURL) } }` (`MediaImportService.swift:102`) keeps the plaintext copies of finished items until the batch ends.
- **Thumbnails:** each is written as a plaintext temp file (`:138-150`; `IncomingMediaFileStore.swift:19-31` re-prepares the directory on every call), then stored with a second `store`.
- **Deletes on main:** `ImportViewModel` (`:54`, `:119-130`, `:157`, `:237`, `:268-275`) and lease cleanup (`SecureMediaPage.swift:270-279`; `SecureTemporaryFileLease.swift:16-28`) call `FileManager.removeItem` synchronously on main.

**P38. Free-space queries.**
*Merges:* IMP-10, SEC-PERF-09.

- **Code:**
  - `MediaImportService.swift:238-244` queries `volumeAvailableCapacityForImportantUsageKey` on a fresh URL for every item.
  - `SecureFileStorageService.swift:135-145` queries it for every temp file, on a long-lived URL that may return cached values (speculative).
- **Cost:** unverified. The CI simulator uses the macOS code path.
- **Not a safe shortcut:** checking the raw available capacity first, because Apple does not document that it is at least the important-usage figure.

**P39. Thumbnail generation.**
*Merges:* PERF-GT-18, IMP-13, IMP-14.

- **Code:** the synchronous ImageIO thumbnail and the deprecated synchronous `copyCGImage` run inside an actor (`ThumbnailGenerator.swift:19-47`). Each call blocks a cooperative-pool thread.
- **Source options:** the source is created with nil options, so `kCGImageSourceShouldCache` defaults to true.
- **HEIC peak:** a full-size HEIC decode is unverified, and the simulator lacks the device's HEVC engine.
- **Scope:** harmless while preparation runs serially; it matters once P09's fix runs it in parallel.

**P40. Bulk file operations.**
*Merges:* PERS-11 (corrected), SEC-PERF-12, the deletion part of PERS-07.

- **Code:** `for item in media { try await storage.move(...) }` (`TrashService.swift:36-39,73-76`; `AlbumService.swift:64-67`). Each move makes two `fileExists` calls plus `moveItem`, `setAttributes` and `setResourceValues` (`SecureFileStorageService.swift:162-181`).
- **Redundant work:** `store` re-protects after the rename (`:106-108`), although a same-volume rename keeps both attributes.
- **Estimate:** about 0.1-0.3 ms per file, with no main-thread stall. Batching removes only the hops, about 10-20%.

**P41. Directory listings.**
*Merges:* SEC-PERF-10 (listing part), the shell auditor's missed issue 2.

- **Code:** `contentsOfDirectory(at:includingPropertiesForKeys: nil, ...)` (`SecureFileStorageService.swift:224-236`). Passing nil prefetches a default set of properties per URL; passing `[]` prefetches none. Each entry then goes through `pathExtension`, `deletingPathExtension().lastPathComponent` and `UUID(uuidString:)`.
- **Estimate:** the possible 10-40% gain is speculative.

**P42. Launch.**
*Merges:* SHELL-10, SHELL-09 (corrected), SHELL-16, X11, the persistence auditor's store-open issue.

- **Bootstrap on main:** `AppModel.bootstrapIfNeeded` is `@MainActor`. It opens the container synchronously, fetches all albums, and lets `SecureFileStorageService.init` prepare 6 directories (about 18 syscalls).
- **No jank, only delay:** the first `LaunchView` frame is already committed, because bootstrap awaits the journal first. So this delays the gate rather than causing jank.
- **Serial start-up:** three of the four awaits in `initializeIfNeeded` (`VaultLockCoordinator.swift:67-94`) go to the same `AuthenticationService` actor, so `async let` cannot overlap them. Only the LAContext query can move off that actor.
- **Launch screen:** the generated, empty `UILaunchScreen` is white in Light Mode before the dark `LaunchView`.

**P43. Small fixed overheads.**
*Merges:* SEC-PERF-08, SEC-PERF-14, SHELL-11 (corrected), SHELL-12, SHELL-13, X12, SEC-PERF-15.

- **Thumbnail decrypt set-up:** about 10 executor switches, an open, 4 reads (header, ciphertext, tag, a 1-byte trailing probe), an HKDF and a SealedBox copy. That is ~0.1-0.3 ms per thumbnail (`SecureFileStorageService.swift:117-125`).
- **Keychain:** `AuthenticationService.unlock` makes 3 Keychain XPC calls, including an unconditional attempt-state delete (`:181-207`).
- **Settings:** `biometricsEnabled` runs a SwiftData fetch on every read (`VaultLockCoordinator.swift:59-61,411-415`), about 5-8 times per unlock attempt.
- **Album sorting:** `sortedAlbums` re-sorts on each of at least 4 reads per body (`AlbumsScreen.swift:20-31`).
- **Shield:** `PrivacyShieldWindow` reassigns its `rootView` on every root update (`PrivacyShieldView.swift:161-165`).
- **Kept:** the per-chunk session hops give other work a fair turn on the actor.

**P44. Reset and existence checks.**
*Merges:* PERS-14, PERS-17.

- **Reset:** `eraseLocalVault` (`VaultLockCoordinator.swift:432-441`) fetches every row and deletes them one by one before a single save.
- **Small fetches:** `containsFingerprint` and `hasPersistedMedia` use fetches with `fetchLimit` 1 as existence checks, and `createAlbum` fetches all albums twice. All of this is negligible or rare.

**P45. iPad multi-window.**
*Merges:* X8.

- **Configuration:** the built Info.plist has `UIApplicationSupportsMultipleScenes = true`.
- **Defects:**
  - Every scene's `.task` runs `cleanupAbandonedIncomingFiles()` (`RootView.swift:102-106`). Opening a second window deletes the first window's incoming files, so its preparation, review or import fails.
  - Every scene forwards its `scenePhase` to the one coordinator, so one window going to the background locks all of them.
- **Memory:** each window builds its own galleries and bitmaps but shares the 64 MiB cache.

**P46. `Assets.car` size.**
*Merges:* X13.

- **Size:** in the CI IPA for `134d9e9`, `Payload/QuietFrame.app/Assets.car` is 30,047,504 bytes, against a 1,832,784-byte binary. The source icons are three SVGs of about 1 KB each.
- **Fix:** CLAUDE.md lists this as a known issue: convert to PNG and keep the Any, Dark and Tinted variants.

### 3.3 Measurement and process problems

- **M1. CI as configured cannot produce trustworthy before/after numbers.**
  - Commit `96ba12b`, which landed after `1c8d5d0`, already runs the benchmarks serially at `-O` with a summary table and a retained log. Still open: the same-job A/B comparison, pinning Xcode, and M2.
  - Debug (`-Onone`) inflates app-side Swift loops: the PBKDF2 XOR, getter loops, sorts and SwiftUI glue. CryptoKit, SQLite and ImageIO are optimized either way, so the before/after ratios get skewed.
  - The test target is parallelizable, so clones share the 3 vCPUs.
  - Results are kept only on failure.
  - Xcode is not pinned, and shared runners are noisy.
  - The test step has a 30-minute timeout inside a 45-minute job.
- **M2. CI exercises only iOS 18 SwiftData (high).** The app targets iOS 17.0, and predicate translation (captured-array `contains`, optional key paths in `fetchCount`) and `@Query` behaviour can differ by OS version. Every number will describe iOS 18 only.
- **M3. Seams are missing.**
  - `GalleryViewModel` takes the concrete `VaultRepository`, although `VaultRepositoryProtocol` already declares what it uses.
  - `AppDependencies` always uses the real Application Support and Caches roots and the production Keychain service, so hosted view tests would touch the simulator app's real vault directories.
  - `IncomingMediaFileStore` uses a fixed directory that the host app also cleans.
  - `AppResetJournal` writes the real marker.
  - The Trash load and post-operation sequence, and the bulk-favourite loop, live inside views and cannot be called from tests.
- **M4. Observation costs.** Model reads inside SwiftUI bodies register observers. Timing the same expressions in plain XCTest understates the cost, so measure through hosted views or inside `withObservationTracking`.
- **M5. Model retention is unverified.** Nobody knows yet whether full-table fetches on `mainContext` keep N models registered after the call returns. That changes memory figures; it is checked by repeating a fetch under `XCTMemoryMetric`.

### 3.4 Corrections applied to the area audits

| Source | Verdict | Applied here |
|---|---|---|
| SHELL-14 (iris preference writes root state) | Refuted | Dropped: `irisSnapshot` is not read in `body`, so writing it does not re-render the root |
| VIEW-16 (30 Hz time observer) | Not an issue | Kept as a constraint: only the scrubber reads `currentTime` |
| SEC-PERF-15 (per-chunk session hops) | Not worth changing | Kept as a constraint: the hops provide fairness |
| VIEW-13 (TabView tag resolution) | Partially | Kept only as a measurement item inside P06 |
| VIEW-14 (bitmap re-commits) | Partially | Folded into P10 (first commit of each new bitmap) and P25; there is no re-commit at every hand-off |
| VIEW-04 | Partially | Retained bitmaps are 4096 px, not full size. ~146-151 MB is certain, the transient peak is unknown, and no jetsam is demonstrated. The fix must not reset zoom when it swaps tiers |
| VIEW-07 | Partially | Applies only with a non-zero auto-lock or no passcode |
| VIEW-12 | Confirmed, raised | Speculative → likely |
| VIEW-20 | Partially | Moving the `@Query` alone is not enough; it also needs the P06 decoupling |
| VIEW-05 / SEC-PERF-02 | Confirmed | The interim fix keeps the capacity check. "Keep the lease within ±1" is already today's behaviour; the real interim step is to key the decrypt on `shouldPrepare` |
| PERF-GT-01 | Confirmed | API attribution fixed (`preparingForDisplay` is iOS 15). Measure with `CATransaction.flush` |
| PERF-GT-05 | Confirmed | Do not page with `fetchIdentifiers` + `model(for:)`, which faults row by row; use one IN-predicate fetch per page |
| PERF-GT-07 / PERS-10 | Confirmed | Any refresh skip must still handle the moving Recently Added cutoff |
| PERF-GT-09 | Confirmed, size halved | Do not enable reporting only while the viewer is shown, because the opening reads frames first |
| PERF-GT-11 | Partially | Certain: realized tiles pin ~140-240 MB on iPad. Speculative: growth from off-screen state |
| PERF-GT-14 | Partially | A selection tap costs ~0.3-1 ms. The viewer's O(n) comes from its own state, not from `hiddenMediaID`, which only adds one pass |
| PERF-GT-16 | Confirmed, raised | Restore never needed the flush; live Trash tiles lose the zoom and the poster |
| PERF-GT-19 / PERS-12 | Partially | An import cannot overlap a Trash visit. The real holders are export and large Trash or album operations |
| PERF-GT-21 / PERS-03 | Partially | A hidden tab re-fetching after every save is speculative. The O(N) render cost is certain and repeats after every unlock |
| PERS-01 / SHELL-01 | Confirmed | PBKDF2 runs off main and probably takes more than 0.15 s, so maintenance dominates for Face ID and no-passcode opens. `async let` on one actor gains nothing. Moving maintenance after unlock first needs a cheap snapshot |
| PERS-02 | Confirmed | The IN predicate must be verified on an iOS 17 runtime |
| PERS-04 / SHELL-05 | Partially | About one relationship build per row per list rebuild. The fallback cover follows NSSet hash order, not insertion order. Ship together with P05's counts |
| PERS-07 | Partially | Deletion costs ~0.2-0.5 s per 1k items, not 1-2 s. No force unwrap in predicates |
| PERS-09 / IMP-3 | Partially | Not independent and speculative. The always-present consumer is `GalleryBrowserContent` |
| PERS-11 | Partially | 2-3× lower; batching gains little |
| PERS-15 | Partially | The collation may make Name, Type and search scope fetches cost tens to 100+ ms at 10k (speculative) |
| SEC-PERF-03 | Partially | Low-medium. Import and export cannot scale anyway; the fix is a separate lane for small decrypts |
| SEC-PERF-04 / IMP-1 / IMP-7 | Partially | ~1.0-1.5× on device, not 2-4×. 4 fixed hops per item; photos are affected too. Most cells are skipped, but equal values still notify |
| SEC-PERF-06 | Confirmed | Only the `readExactly` copy and one syscall per path can be removed |
| SEC-PERF-07 | Confirmed | The exact-size check must run before the cap check |
| SEC-PERF-09 / IMP-10 | Partially | The size is unknown and needs a device. The raw-capacity shortcut is not compatible |
| SEC-PERF-10 | Partially | The listing is the smaller part, and nothing contends for the storage actor before `.unlocked` |
| SEC-PERF-11 / SHELL-04 | Confirmed | Adds the main-thread sort. Keep the missing-file error type. Do not cache on `didSave`; add a tie-break |
| SEC-PERF-16 / IMP-4 | Confirmed | Use a size pre-filter that includes trashed rows; avoid an unindexed per-item `byteCount` query |
| IMP-9 | Partially | The fsync must stay; privacy is the main reason for the change |
| IMP-11 | Partially | The decrypt path is worse than encrypt; thumbnail queuing is at most one chunk |
| IMP-13 | Partially | Add `kCGImageSourceShouldCache: false`; the HEIC peak needs a device |
| IMP-17 | Partially | The decode happens on main, so seeding the cache with undecoded images helps nothing |
| SHELL-07 | Partially | Umbrella issue. No-passcode inactive→active does not lock |
| SHELL-09 | Partially | Only the LAContext call can overlap the others |
| SHELL-11 | Partially | UnlockView's `body` does not read `passcode`: ~5-8 fetches per attempt, not one per digit |
| SHELL-16 | Confirmed | `UIUserInterfaceStyle = Dark` gives black, not night. An exact colour needs an Info.plist partial |

### 3.5 Correctness and security observations that constrain the rebuild

1. **Reconcile has no safeguard against mass deletion.** If the metadata store ever opens empty or wrong, the next unlock deletes every encrypted file. That could happen through a configuration name change, an explicit URL, or an App Group entitlement combined with `.automatic`. The store location must stay fixed (5.1), and a ratio guard is proposed (6.4).
2. **`ModelConfiguration` defaults to `.automatic`** for `groupContainer` and `cloudKitDatabase`. That is harmless only because the entitlements contain no App Group or iCloud container.
3. **Locking with the viewer open** relies on SwiftUI dismissing the cover implicitly. The rebuild should dismiss the viewer explicitly, without animation.
4. **The viewer keeps a deleted model** during the fade after a permanent delete. Work from value snapshots instead.
5. **Every re-wrap bumps the session generation** (add, remove or change passcode, normal reset), which revokes in-flight decrypts. Keep this or change it deliberately.
6. **Header fields are unauthenticated** until the first tag verifies. Any `reserveCapacity` must come after an exact-size check and be clamped to the cap.
7. **`decrypt` opens its FileHandle outside its `do/catch`.** Today the `fileExists` pre-check masks this. If the pre-check goes away, open failures must map to `corruptedFile`.
8. **Wrong error mappings:** a write failure during `decryptFile` (for example ENOSPC) becomes `corruptedFile`, and a cancelled export shows `importCancelled`'s message.
9. **The gate closures rely on Swift 5 isolation inference.** A Swift 6 migration needs a different gate API.
10. **`AppResetJournal` always targets the real Application Support** directory, including in tests.
11. **`allIdentifiers` keeps uppercase UUID names,** which never match the lowercase references, so such files would be deleted as orphans. This affects only files placed from outside the app.

---

## 4. Proposed architecture

The guiding rule: replace technology only where an issue in section 3 shows it is the cause. No new database, no third-party code, no on-disk cache of decrypted data, no logging or signposts in the app (all timing stays in XCTest), and no change to any CLAUDE.md security invariant.

### 4.1 Summary

| Subsystem | Verdict | What changes | Issues | Phase |
|---|---|---|---|---|
| Container format, key hierarchy, file layout | KEEP | Nothing | — | — |
| Crypto service (`ChunkedEncryptionService`) | KEEP the actor and format; REBUILD the loop internals | Single read per chunk, reused buffers, exact-size check before `reserveCapacity`, no fsync for temp outputs, a separate lane for small decrypts | P20, P31, P43 | 1, 2 |
| `SecureFileStorageService` | KEEP the API and layout; EXTEND | Name-based listings, bulk sizes, `store(plaintextData:)`, batch move and delete, capacity checked once per batch | P15, P37, P38, P40, P41 | 1, 6 |
| PBKDF2 | REBUILD the implementation | CommonCrypto `CCKeyDerivationPBKDF`, byte-identical output | P14 | 1 |
| Authentication and Keychain | KEEP | Delete the attempt state only after a failure; LAContext query off the actor | P42, P43 | 4 |
| SwiftData store, VaultSchemaV3, migration plan | KEEP | Query shapes only: IN predicates, `fetchCount`, `propertiesToFetch`, sorting in the store, a save-driven change monitor | P04, P05, P08, P11, P12, P15, P23, P44 | 1-3 |
| SwiftData main-actor rule | KEEP (exception only if measured) | Optional read-only snapshot context off main, requires a CLAUDE.md amendment | P03, P04 | 3-4 |
| Thumbnail pipeline | REBUILD | Tiered cache, decode off main, cancellable scheduler, prefetch, targeted eviction | P01, P02, P16, P30, P34 | 2 |
| Gallery grid (`LazyVGrid`) | KEEP | Stable inputs, frames in content space, a small hidden-tile observable | P26, P27, P28 | 3 |
| Gallery data flow | REBUILD | ID arrays, look-ahead paging, cached search results, refresh only on change | P04, P11, P12, P27 | 3 |
| Albums screen | REBUILD the data source | Counts and row snapshots from `fetchCount` | P05, P29 | 3 |
| Trash, album, reconcile and analysis services | KEEP semantics; REBUILD queries | IN predicates, batch storage calls, Trash tab loads before it purges | P08, P15, P19, P23, P40 | 1, 3 |
| Unlock path and maintenance | KEEP semantics and gate; REBUILD cost (timing needs sign-off) | Snapshot reconcile, name listings, mass-deletion guard, maintenance after the unlock animation | P03, P25, P32 | 4 |
| Bootstrap and launch | KEEP order | Container opened off main, launch colour (sign-off) | P42 | 4 |
| Viewer pager | KEEP `TabView(.page)`; REBUILD identity and state | ID array and index map, lift state isolated, hidden tile decoupled from the presenter | P06, P25, P35 | 5 |
| Viewer photo loading | REBUILD the policy | Screen-fit tier plus zoom tier, byte budget, memory warnings, small LRU | P10, P24 | 5 |
| Video playback | REBUILD in two steps | Viewer-level session owner and no fsync (Phase 5); streaming resource loader (Phase 7) | P07, P20, P33, P36 | 5, 7 |
| Import | KEEP gate and order; REBUILD around them | Throttled progress, bounded parallel preparation, eligibility off main, on-demand previews, per-item cleanup, size pre-filter | P09, P13, P17, P21, P22, P37, P38, P39 | 1, 6 |
| Export | KEEP the all-or-nothing leases | No fsync, aggregate capacity check, one IN fetch | P18 | 1, 6 |
| Operation gate | KEEP | Optional early exit in long holders after a lock | P03 | 4 |
| Lock boundary and cache purge on lock | KEEP | — (security invariant) | P32 | — |
| Privacy shield, theme, motion | KEEP | Assign the shield's `rootView` only when it changes | P43 | 4 |

### 4.2 Decisions evaluated and rejected

- **A new database, raw SQLite or Core Data.** Rejected. The measured-in-code costs come from query shape: whole-table fetches, materializing models, per-item saves. They do not come from SwiftData itself, and changing the store risks the data. SQLite scans at 10k rows cost a few ms (speculative).
- **`#Index` or any schema change.** Rejected for this rebuild. `#Index` needs iOS 18, the schema must be identical on every supported OS, and any model edit forces a V4 schema with a migration. The risk outweighs the gain (P12 is medium).
- **Rewriting the grid as a `UICollectionView`.** Deferred. Every grid cost in section 3 can be fixed inside SwiftUI. A UIKit grid would put at risk the context-menu preview shape, long press, accessibility actions, `.searchable` and `.refreshable` integration, scroll retention and the zoom hand-off. Reconsider only if device measurements after Phase 3 still show hitches.
- **Replacing `TabView(.page)` in the viewer.** Deferred. The O(n) cost comes from identity and linear scans, not from `TabView` (VIEW-13 is unproven). Reconsider if B6 still grows with N after the Phase 5 identity fix.
- **Image or caching libraries.** Rejected. `NSCache` plus ImageIO cover every need, and third-party code is forbidden.
- **Batching import saves.** Not by default. Per-item saves give crash durability: a stored file without a row is deleted by reconcile. Revisit only if B5 and B9 show the per-save cost dominating after P05 is fixed.
- **Encrypting several import or export files in parallel.** Rejected. Duplicate detection must stay serialized with the insert, because the unique `contentFingerprint` upserts, and the gate protects reconcile. Preparation is where parallelism helps.
- **Disk caches for thumbnails, previews or the search index.** Rejected, because they would put plaintext on disk. All new caches are memory-only and cleared on lock.

### 4.3 Subsystem details

**Crypto service: KEEP the format and the actor; REBUILD the internals.**

- **Changes:**
  - **Reads and writes:** read ciphertext and tag in one read into a reused buffer, and return the first read directly when it is already complete. Write ciphertext and tag with one call. Keep one AAD buffer and rewrite only its 4-byte index.
  - **`decryptData` order:**
    1. `fstat` the file;
    2. require size = 48 + P + 16·ceil(P/C), else `corruptedFile`;
    3. apply the cap, else `insufficientStorage`;
    4. `reserveCapacity(P)`.

    The order matters, because the header is unauthenticated until the first tag verifies. A file of one chunk or less returns its opened plaintext directly.
  - **fsync:** remove it from `decryptFile`, whose output is always a temp file. Keep it in `encryptFile`.
  - **Small-decrypt lane:** `AppDependencies` builds a second `ChunkedEncryptionService` and a second `SecureFileStorageService` over the same roots and the same `VaultSession`, used only by the thumbnail and filmstrip paths. Two actor instances means two executors, so thumbnail decrypts never queue behind a video decrypt or an import. The code, the per-chunk `validate` and the error mapping stay identical.
- **Why:** P31 and P20; this also helps the P16 latency.
- **Expected effect:** about one copy and one syscall fewer per MiB; thumbnail latency during large jobs falls from about 4 chunk turns to roughly zero; the fsync wait disappears from temp outputs.
- **Risk:** this code is security-critical. Phase 0 locks it down with the legacy cross-decrypt, tamper and lock-revocation tests (5.1).

**`SecureFileStorageService`: KEEP; EXTEND.**

- **New API:**
  - `listIdentifiers(locations:)`: nonisolated, name-based (`contentsOfDirectory(atPath:)`), with the same filter (no dot-names, extension `qfe`, UUID stem, case kept). Returns all three sets in one call.
  - `byteCounts(location:)` using `.fileSizeKey`.
  - `store(plaintextData:location:)`: produces the same container bytes and keeps the fsync, but writes no plaintext temp file and computes no fingerprint for thumbnails.
  - `move(identifiers:from:to:)` and `delete(identifiers:location:)`: batch calls that return per-item results so callers can roll back.
- **Behaviour:**
  - Capacity is queried once per batch on a fresh URL, then decremented by the bytes written. The exact rule and error stay.
  - File protection is applied at creation, and the backup flag is set once on the staging file (rename keeps both). Verify on a device (SECURITY checklist item).
- **Test doubles:** `MockSecureFileStorage`, `RecordingPhotoStorage` and `GatedPhotoStorage` gain the new protocol methods.

**PBKDF2: REBUILD the implementation.**

- **Change:** `CCKeyDerivationPBKDF(kCCPBKDF2, …, kCCPRFHmacAlgSHA256, rounds: UInt32(iterations), …, 32)`. The signature and the per-envelope iteration count stay. A status other than success maps to `invalidInput`.
- **Expected effect:** ~15-40 ms on a device instead of an estimated 0.15-0.4 s per derivation.
- **Proof:** the known-answer vectors in 5.2, plus a differential test against the legacy loop kept in the test target.
- **Docs:** update SECURITY.md:26.

**SwiftData persistence: KEEP; REBUILD query patterns.**

- **Lookups by ID set** (Trash operations, `moveMedia`, `exportItems`, bulk favourite): `let idList = Array(ids)` with `#Predicate { idList.contains($0.id) }`, chunked at 500 or fewer, restored to input order where order matters, keeping today's count checks and errors. Verify translation on an iOS 17 runtime (M2).
- **Counts:** `fetchCount` (Albums collections, per-album counts, analysis media count).
- **Narrow scans:** `propertiesToFetch` for scans that need few columns (reconcile snapshot, search keys, analysis join). These still create partial models, so the win comes from one pass and fewer faulted columns.
- **Top N:** sorted fetch with `fetchLimit` (analysis "Largest files": `byteCount` descending, then `storageIdentifier`).
- **Change tracking:** a `VaultChangeMonitor` (`@MainActor @Observable`) counts `ModelContext.didSave` notifications and keeps the changed IDs. The gallery refresh skip, the Albums counts and search invalidation all use it.
- **Unchanged:** no model edits, so the V3 checksum stays.
- **Main-actor rule:** stays the default. If B2 or B4 show that the main-thread part is still over budget after the query changes, allow one exception: read-only snapshot fetches in a short-lived `ModelContext` created off main (reconcile snapshot, search keys). Writes stay on `mainContext`. This needs an explicit CLAUDE.md amendment. Snapshots stay consistent because every write saves immediately and file locations change only inside the gate.

**Thumbnail pipeline: REBUILD** (`ThumbnailService` keeps its public API: `image(for:)`, synchronous `cachedImage(for:)`, `clearCache()`).

- **Tiers, all in memory and all cleared by the lock-time generation bump:**
  1. The encrypted file, unchanged.
  2. Decrypted JPEG `Data`, in an LRU with a byte budget (16-32 MB, roughly 200-300 items).
  3. Decoded bitmaps keyed by (identifier, pixel size), cost = `bytesPerRow × height`. The budget starts around 48-64 MB, tuned by B1 and B3 so that two screens fit on the largest iPad.
- **Decoding:** done off main with `CGImageSourceCreateThumbnailAtIndex` (`MaxPixelSize` = tile pixel size, `ShouldCacheImmediately`, `.userInitiated`). The pixel size is computed once per grid from the column width × display scale, not per tile.
- **Viewer compatibility:** `cachedImage(for:)` must still return at least today's 720-px quality. It returns a 720-px decode if one is cached; otherwise it decodes one synchronously from tier 2 (~2-3 ms, at most once per viewer open); otherwise nil (today's fade fallback).
- **Scheduling:**
  - Requests per identifier share one job and count their waiters (`withTaskCancellationHandler`). The job is cancelled when the last waiter leaves before decrypt or decode starts.
  - At most 3 jobs run at once, newest first.
  - Results that no one is waiting for go only into tier 2.
  - Prefetch covers 1-2 screens in the scroll direction at low priority and is cancelled on direction change and on lock.
  - `adopt(_:for:)` re-inserts an image that a re-appearing tile already holds.
- **Tiles:** render `image ?? cachedTileImage(...)` synchronously (fixes P34).
- **Eviction:**
  - A lock purges every tier (unchanged semantics).
  - Permanent delete, Empty Trash and purge evict exactly the deleted thumbnail identifiers; Restore evicts nothing.
  - The `tasks[identifier] = nil` race is fixed, and failures are remembered per generation instead of retried on every appearance.
- **Expected effect (deterministic where stated):**
  - main-thread decode per tile goes to zero;
  - bytes per iPhone 16 Pro Comfortable entry fall from 1,555,200 to ~623,808;
  - decrypts for cancelled requests fall to about the in-flight limit;
  - Trash operations cause no re-decrypts of unrelated tiles;
  - the opening zoom no longer falls back to a fade for tiles whose JPEG is in tier 2.
- **Risk:** low-medium. Viewer quality must stay at least the same, the lock purge must be complete, and no continuation may leak.

**Gallery data flow: REBUILD; the grid view: KEEP `LazyVGrid`.** Each step is gated by evidence, because P12 and P27 are only likely or speculative.

- **Step 1** (always):
  - Load ahead when an item within the last ~24 appears.
  - Guard paging with a generation, so a filter or search change cannot append mixed results (fixes the race quirk; approval in 6.4).
  - Never reassign `items` when the IDs are unchanged.
  - Skip `refreshLoadedItems` when the `VaultChangeMonitor` count is unchanged since the last load. The Recently Added collection is the exception: it always refreshes on re-appearance (or when the oldest loaded item's `importedAt` + 30 days has passed).
- **Step 2** (always), search:
  1. Get the ordered scope IDs from SQLite with today's `SortDescriptor`s, using a minimal-column fetch. This keeps the collation and NULL order exact.
  2. Compute the match set off main from Sendable search-key snapshots (filename, album name, tags, `importedAt`, `originalCreationDate`), with the identical predicate: `localizedCaseInsensitiveContains`, `.medium` `DateFormatter` strings in the current locale and time zone (memoized per calendar day), and an exact year match.
  3. Matches = scope IDs filtered by the match set.
  4. Pages slice those IDs, and each page loads with one chunked IN fetch, reordered.

  The result is cached per (query, change count, day, locale, time zone); cleared on `NSLocale.currentLocaleDidChangeNotification`, `.NSSystemTimeZoneDidChange` and on lock; and recomputed on demand with cancellation.
- **Step 3** (only if B2 shows deep or collation-heavy pages above budget): the same ordered-ID cache for browsing without a search.
- **Grid view:**
  - `GalleryViewModel` keeps `items` (used by `GallerySortingTests`) and adds `itemIDs` and `indexByID`, built once per data change.
  - Tile frames are reported with `onGeometryChange` in the grid's content coordinate space, so they stay constant while scrolling. One viewport/offset reader converts them to window coordinates when the viewer opens or closes. The `MediaTileFrames` contract is unchanged.
  - `hiddenMediaID` moves into a small `@Observable` that only the tile opacity reads.
  - Grid closures become one stable action object, so SwiftUI can skip the grid.
  - Accessibility labels are memoized per (id, `modifiedAt`, album name, locale).
- **Expected effect:**
  - search costs O(scope) once per query and data version instead of per page and per refresh;
  - refreshes fetch zero rows when nothing changed;
  - per-frame tile frame work disappears;
  - page changes no longer re-render the grid.
- **Risk:** medium. Ordering and search must match exactly (OrderingParityTests, SearchParityTests), and so must refresh semantics (`GallerySortingTests`).

**Albums screen: REBUILD its data source.**

- **Model:** an `AlbumsOverviewModel` (`@MainActor @Observable`). It refreshes on appear, on foreground and on `didSave` (coalesced to about 250 ms during imports). It holds:
  - three `fetchCount` totals;
  - per-album row snapshots: id, name, active count (`fetchCount` on `album?.id == id && trashedAt == nil`), cover thumbnail identifier, cover media type;
  - albums sorted once per change.
- **Cover rule:** if `coverMediaID` is a non-trashed member, fetch it by ID. Otherwise apply today's fallback (first non-trashed member of the relationship), evaluated once per data change instead of on every render. Any deterministic fallback order is a visible change and needs approval (6.4).
- **Rule:** ship together with the removal of the `activeMedia` query (see P05).
- **Expected effect:** the first visit runs three COUNT queries instead of materializing N models; a save costs O(albums) small queries.

**Trash, album, reconcile and analysis services: KEEP semantics; REBUILD queries.**

- **Trash:** IN-predicate fetches; restore looks albums up in a dictionary.
- **Purge:** exits early by fetching the oldest trashed item (`trashedAt != nil`, sorted ascending, `fetchLimit` 1) and comparing with the cutoff in Swift. No force unwrap. It then fetches only the expired rows and deletes them in one batch storage call.
- **Empty Trash:** fetches the trashed rows once.
- **Storage analysis:**
  - three `byteCounts(location:)` calls joined with a `propertiesToFetch` snapshot;
  - the top 20 fetched sorted from the store;
  - cancellation checked, and only one analysis in flight;
  - a missing referenced file still fails with the same kind of error.
- **Trash tab:** load the page first, then purge, then refresh if anything was deleted. A `CancellationError` stays silent.
- **Bulk favourite:** one IN fetch. Whether it then makes one save (atomic) or keeps today's per-item saves is a decision for 6.4.

**Unlock path: KEEP semantics and the gate; REBUILD the cost; changing the timing needs sign-off.**

- **Reconcile** becomes:
  1. one-pass Sets from a `propertiesToFetch` snapshot (`storageIdentifier`, `thumbnailIdentifier`, `trashedAt`);
  2. one nonisolated, name-based listing call;
  3. batched repairs.

  The semantics are unchanged.
- **Mass-deletion guard (new, needs sign-off):** skip orphan deletion and report when it would delete more than a set fraction of a location's files, or when the store has zero rows but files exist.
- **Timing (sign-off):** set `.unlocked` as soon as the key is in the session, and start maintenance in a task that holds the gate after the unlock transition finishes (~0.5 s). Only do this once its main-thread part is small. When it finishes, open galleries refresh if it repaired, deleted or purged anything, and the viewer tolerates items that disappear. This also fixes the known issue where a maintenance failure blocks unlock; the replacement failure UX must be specified.
- **Gate:** optionally, long gate holders (`deleteAlbum`, `emptyTrash`, export decrypt loops) stop between items once the session generation changes, ending through their existing rollback paths.
- **Authentication:** delete the attempt state only if a failure was recorded; make the LAContext query `nonisolated`.

**Bootstrap and launch: KEEP the order.**

- Create the `ModelContainer` off main after the journal finishes (`ModelContainer` is Sendable), with the same configuration and URL, then hop back.
- Album positions: same rule, applied only when needed.
- Launch-screen colour: needs sign-off (6.4).

**Viewer pager: KEEP `TabView(.page)`; REBUILD identity and state.**

- **Identity:** the presenter passes, alongside today's `items`, an ID array and index map built once per data change. `ForEach(itemIDs, id: \.self)` with `.tag(id)` never touches SwiftData for identity. `selectedIndex` lives in state.
- **Lift:** the lift translation moves into a small `@Observable` read only by the transform modifier and the backdrop. The pager is a child view with Equatable value inputs and one stable action object.
- **Hidden tile:** `hiddenMediaID` moves to the shared hidden-tile observable, so page changes no longer re-render or re-create anything in the presenter.
- **Smaller fixes:**
  - the albums `@Query` moves into the Move sheet;
  - caption and accessibility strings are memoized;
  - filmstrip thumbnails go into a viewer-owned cache that survives chrome toggles. Keeping the chrome mounted is not proposed, because it could change VoiceOver behaviour.
- **Lock:** the viewer is dismissed explicitly, without animation, when the state leaves `.unlocked` (3.5 item 3).

**Viewer photo loading: REBUILD the policy.**

- **Tiers:** a screen-fit rendition (longest side = viewer bounds × scale) for neighbours and the unzoomed page. The 4096-px tier is decoded in the background for the selected page right after its screen-fit tier, or on the first zoom, and dropped on page change. README and SECURITY still hold: zoom resolution stays 4096 px.
- **No zoom reset:** `ZoomingImageScrollView.display(_:)` must swap in a same-aspect bitmap without refitting or resetting the zoom.
- **Memory:**
  - a byte budget, plus a small LRU of screen-fit renditions cleared on close and on lock;
  - `UIApplication.didReceiveMemoryWarningNotification` drops the neighbours and the zoom tier;
  - the decrypted `Data` is released once the decode starts.
- **Scheduling:** decrypt and decode are pipelined within the budget, with a cancellation check before publishing. There is one observable slot per media ID.
- **Expected effect:** resident memory falls from ~146-151 MB to roughly one 4096 bitmap plus two screen-fit renditions (B6 measures the exact bytes).
- **Risk:** this deliberately changes the one-decrypt-at-a-time policy that `ViewerPhotoLoaderTests` encode.

**Video playback: REBUILD in two steps.**

- **Phase 5:**
  - A viewer-level `VideoSessionController` keyed by media ID owns the lease, player and looper. It releases them when the item leaves the ±1 window, on close and on lock, independent of view appearance (fixes VIEW-12).
  - The decrypt is keyed on `shouldPrepare`. `scenePhase` is handled with `onChange` for pause and resume, and playback never starts while inactive (fixes P33).
  - No fsync on the temp file.
  - The scrubber chases seeks: one seek in flight, toleranced while dragging, exact on release.
  - The frame strip reuses the playback asset, starts after the first frame is shown, and publishes its frames once.
- **Phase 7, streaming:**
  - An `AVURLAsset` with a custom URL scheme, served in-process by an `AVAssetResourceLoaderDelegate`. There is no networking.
  - Content information: the UTType from `contentTypeIdentifier`, `contentLength = plaintextByteCount`, byte-range support.
  - Data requests: decrypt only the covering chunks (chunk k at 48 + k·(C+16), nonce prefix‖k, AAD header‖k), after an up-front exact-size check that replaces sequential truncation detection. A small LRU of decrypted chunks, a per-chunk session check, and a lock that fails pending requests.
  - The same asset feeds `AVPlayerLooper` and the frame generator. Share and Save to Photos keep temp leases.
- **Expected effect:** time to first frame stops depending on file size, and no plaintext video lands on disk during playback.
- **Docs and behaviour:** README limitation 7 and the SECURITY temp-file text change, and playback no longer needs free space (6.4).

**Import: KEEP the gate and the store → dedup → insert order; REBUILD around them.**

- **Progress:** `MediaImportService` forwards a fraction only when it has moved by at least 1% or 33 ms have passed, always including 0 and the final value, and keeps awaiting the forwarded ticks so order and backpressure stay. The view model ignores equal values. Progress-dependent UI moves into leaf views, and the grid scrolls only when the target row changes.
- **Preparation:**
  - a bounded task group of 2-3, with results written by selection index;
  - metadata and thumbnail extraction as nonisolated static functions sharing one source per item (`kCGImageSourceShouldCache: false`);
  - a pixel budget computed from the header's pixel size;
  - the async `AVAssetImageGenerator.image(at:)`;
  - per-child cleanup, and unchanged counts and warnings.
- **Eligibility:** computed off main after the picker returns, from the live-photo flag plus one batched `fetchAssets` and a dictionary by `localIdentifier`. Same rules.
- **Previews:** `candidates` keep the JPEG `Data`. Images are decoded on demand off main at tile size into a byte-bounded `NSCache` (32-48 MB, cleared on dismiss and lock), and the first screen is prefetched.
- **Files:**
  - each incoming file is deleted off main as soon as its item finishes;
  - thumbnails go through `store(plaintextData:)`;
  - capacity is checked once per batch;
  - duplicates: load the set of existing `byteCount` values (trashed included) once per batch, and hash before encrypting only when the size matches, reporting progress during the hash.
- **Saves:** stay per item.

**Export: KEEP the all-or-nothing temp leases.**

- No fsync on temp outputs.
- One capacity check up front for the total. It is equivalent for an all-or-nothing operation; it only fails earlier.
- `exportItems` makes one IN fetch and keeps input order and errors.
- Lazy share providers or a progress UI are UX changes (6.4).

**Operation gate, lock boundary, privacy shield: KEEP.**

- The gate stays FIFO and non-reentrant.
- The lock still sets `.locked` before any `await` and purges the caches.
- The shield window still appears synchronously on `willDeactivate`. Its `rootView` is assigned only when the capture state changes.

---

## 5. Data compatibility risks

### 5.1 Invariants and how each phase proves them

The "Proof" column names tests added in Phase 0 (section 6.3) or existing tests. Every phase must pass all of them with no change to any fixture.

| # | Invariant (exact) | Can be broken by | Proof |
|---|---|---|---|
| 1 | **Container header**, 48 bytes, big-endian: magic `51 46 52 41 4D 45 30 31` ("QFRAME01"), version `0x01`, flags `0x00`, reserved UInt16 `0`, chunk size UInt32 (writer 1,048,576; reader accepts 65,536-16,777,216), plaintext size UInt64 > 0, 16-byte salt, 8-byte nonce prefix | P31 loop rewrite, `store(plaintextData:)`, P07 streaming reader | `ContainerCompatibilityTests`: decrypt fixtures written by today's code; a reference decoder written from this spec in the test target; structural checks on new output; legacy ↔ new cross-decryption |
| 2 | **Container body:** per chunk, the ciphertext followed by a 16-byte tag; no padding or trailer; size = 48 + P + 16·ceil(P/C). Trailing bytes, truncation or an index ≥ UInt32.max give `corruptedFile` | P31, P07 | Tamper suite: each header field flipped, truncation by 1 byte, 1 byte appended, two chunks swapped, a tag byte flipped, the wrong master key; all must give `corruptedFile` and delete partial output |
| 3 | **Per-chunk AEAD:** AES-256-GCM, nonce = 8-byte prefix ‖ UInt32 BE index, AAD = the 48-byte header ‖ UInt32 BE index | P07, P31 | Reference decoder; streaming random-range reads compared byte for byte with sequential decryption (Phase 7) |
| 4 | **File key** = HKDF-SHA256(IKM = master, salt = header salt, info = "QuietFrame.file-key.v1", 32 bytes) | P31, P07 | File-key vector (5.2) in the reference decoder; fixtures |
| 5 | **Duplicate fingerprint** = lowercase hex of HMAC-SHA256(HKDF-SHA256(master, empty salt, "QuietFrame.deduplication-key.v1", 32), SHA-256(plaintext)), stored in `contentFingerprint` (unique), matched against every row including trashed ones | P21 pre-hash, P31 | `FingerprintVectorTests` (5.2); legacy and new produce equal fingerprints; duplicate tests including Trash and within one batch |
| 6 | **Lock revocation:** key access captured once; `checkCancellation` and `validate(generation)` before every chunk and at completion; partial output deleted. Errors: lock → `authenticationRequired`; cancelling a file operation → `importCancelled`; cancelling `decryptData` → `CancellationError` | Small-decrypt lane, streaming, P31 | Existing lock-at-next-chunk test, extended to the second lane, to streaming reads (pending requests fail) and to temp leases |
| 7 | **Passcode envelope:** account `passcode-envelope-v1`; default `JSONEncoder` output of {version 1, salt (base64, 16 B), iterations 210000, verifier (base64, 32 B), sealedMasterKey (base64, 60 B)}. PBKDF2-HMAC-SHA256 over the UTF-8 passcode, using the envelope's salt and iteration count (1…2,000,000), 32 bytes. The verifier is HMAC-SHA256(wrapping key, "QuietFrame.passcode.verifier.v1"), compared in constant time. The master key is sealed with AES-GCM, AAD "QuietFrame.master-key.v1" | P14 | PBKDF2 vectors and verifier vector (5.2); differential test (legacy loop vs CommonCrypto over random passcodes, salts of 16-64 B and iteration counts including 210,000); `EnvelopeFixtureTests` (an envelope captured from today's code plus the passcode must yield the recorded master key) |
| 8 | **Keychain:** service `com.quietframe.vault.security`; accounts `passcode-envelope-v1`, `unwrapped-master-key-v1`, `biometric-master-key-v1`, `attempt-state-v1`. Every item `WhenUnlockedThisDeviceOnly`, non-synchronizable, no access group. The biometric item is `WhenPasscodeSetThisDeviceOnly` + `.biometryCurrentSet`, written as delete + add. The attempt state is JSON {failedCount, blockedUntil (default Date strategy, omitted when nil)}. Lockout delays as listed in 2.3 | P43 attempt-state change | Existing `KeychainServiceTests` and `AuthenticationServiceTests`; `AttemptStateFixtureTests`; a full lockout-schedule test with an injected clock |
| 9 | **Master key never changes** on add, remove or change passcode. Mode resolution: envelope → passcode; raw key → none; neither → not configured (or recovery if media rows exist) | Auth changes | Existing tests for add, remove and change passcode keeping the key |
| 10 | **Schema:** `VaultSchemaV1` 1.0.0, `V2` 2.0.0, `V3` 3.0.0 (the live classes). Lightweight stages V1→V2 and V2→V3; the frozen V1 and V2 nested copies are untouched. **Any edit to `VaultMedia`, `VaultAlbum`, `AppSettings` or `ImportRecord` changes the V3 checksum**, and existing stores would then fail to open | Anyone adding a stored property, for example to cache search keys. Forbidden in this rebuild | Existing on-disk V1→V3 and V2→V3 tests; `SchemaShapeSnapshotTests` (entities, attributes, types, optionality, unique options, relationships and delete rules of `Schema(versionedSchema: VaultSchemaV3.self)` compared with a committed text snapshot); `V3StoreFixtureTests` (open a V3 store captured from today's code and check every field) |
| 11 | **Store location:** `ModelConfiguration(schema:isStoredInMemoryOnly: false)` resolves to `Application Support/default.store` (+ `-wal`, `-shm`), default configuration name; `groupContainer` and `cloudKitDatabase` stay `.automatic` and inert. Moving the store opens an empty one, and the next reconcile would then delete every file (3.5) | P42 (container off main), any `AppModel` refactor | `StoreLocationTests` (configuration URL and name); review of the entitlements diff |
| 12 | **On-disk layout:** `QuietFrameVault/{media,thumbnails,trash}/<lowercase uuid>.qfe`; `staging/<uuid>.partial`; `Caches/QuietFrameTemporary/<uuid>[.ext of up to 8 a-z0-9]`; `tmp/QuietFrameIncoming/<uuid>.<ext>`; `Application Support/reset-in-progress` with content "QuietFrame reset v1". `EncryptedAssetLocation` raw values are the directory names | Bulk storage APIs, seam S4, streaming | `StorageLayoutTests` under a temp root; `allIdentifiers` filter test (hidden files, wrong extension, non-UUID stem, uppercase) |
| 13 | **Every created file and directory** gets `FileProtectionType.complete`, `isExcludedFromBackup` and a random UUID name | P40 (fewer attribute calls) | Read-back test on the simulator (`.protectionKey` from `attributesOfItem`, `isExcludedFromBackup` from resource values) with `applyFileProtection: true`; device check in Phase 8 (the simulator does not enforce protection classes) |
| 14 | **Raw values:** identifiers are lowercase UUID strings; `MediaType` 'photo'/'video'; `autoLockSeconds` 0/30/60/300; `trashRetentionDays` 7/15/30; appearance system/light/dark; thumbnail size compact/comfortable/large; album sort manual/name/creationDate/modifiedDate; album media direction newestFirst/oldestFirst; `ImportStatus` running/completed/cancelled/failed | Any refactor | `RawValueTests`; V3 fixture |
| 15 | **Thumbnail artifact:** JPEG, longest side ≤ 720 px, quality 0.82, orientation applied (photo: `CreateThumbnailWithTransform` + `FromImageAlways`; video: frame at 0.1 s with the preferred transform). Encrypted into `thumbnails/`, never rewritten in place; `thumbnailIdentifier` is nil on failure | P39, `store(plaintextData:)` | `ThumbnailGeneratorTests` (size, decodable JPEG, a rotated EXIF fixture); container equivalence |
| 16 | **Gallery ordering:** the exact `SortDescriptor` arrays at `VaultRepository.swift:381-405`, including the `localizedStandard` comparator on String keys and the `storageIdentifier` ascending tie-break; NULL creation dates last for newest-first and first for oldest-first; Type is photo before video, then `importedAt` descending; Size descending; Name ascending; the direction applies only to date sorts; Trash sorts by import date | Any ordering done in memory (ID caches, search) | `GallerySortingTests` (17); `OrderingParityTests`: every sort × direction × scope over a seeded 2,000-item set (names IMG_2/IMG_10, Résumé/resume/RESUME, emoji, nil; equal timestamps; nil creation dates; UUID tie-breaks starting with digits and with letters). The new ordered IDs must equal the legacy oracle's exactly |
| 17 | **Scopes and filters:** the 16 predicates; Recently Added = `importedAt >= Calendar.current.date(byAdding: .day, value: -30, to: now)` evaluated per fetch; the Favorites collection treats the Favorites filter as All; Trash ignores album and collection | Query-layer rebuild | `FilterScopeTests`: all 16 combinations; cutoff ±1 minute around 30 days |
| 18 | **Search:** trimmed text; match if any of `localizedCaseInsensitiveContains` on filename, album name or any tag; `.medium`/`.none` `DateFormatter` strings (current locale and time zone) of `importedAt` and `originalCreationDate`; an exact import-year string. Scope and filter apply, the current sort holds, pages of 80, 250 ms debounce | P04 | `SearchParityTests`: new against the legacy oracle (a test-target copy of today's filter) for 30 query strings × scopes × filters, in the simulator's locale |
| 19 | **Paging and refresh:** 80 per page; `hasMore` from limit+1; refresh-in-place paths versus start-over paths; selection intersection; paging re-armed; Recently Added items age out on re-appearance | P11, P12 | `GallerySortingTests` refresh tests, plus: aging-out on refresh; look-ahead leaves page contents unchanged; skipping an unchanged refresh keeps identical items |
| 20 | **Mutation rules:** album `modifiedAt` bump rules (2.11); cover clearing; `previousAlbumID`; restore into the previous album only if it still exists; moves are files first with reverse rollback; deletes are metadata first; purge cutoff is inclusive with the raw retention value (30 when there is no settings row); reconcile rules (2.14); storage-analysis semantics (2.13); `moveMedia` is all or nothing | P08, P19, P23, P40, maintenance changes | `RepositoryMutationTests`, `TrashRulesTests`, `ReconcileRulesTests`, `StorageAnalysisRulesTests` (Phase 0) |
| 21 | **Import:** `importedAt` strictly increasing in source order; duplicates matched including Trash and within the batch; `ImportRecord` written at begin and finish; summary rules; `ImportProgress` contract (source order, monotonic `completedItems`, fraction × 0.9, item boundaries); the gate held for the whole batch; eligibility rules unchanged | P09, P17, P21, P29, P37 | `MediaImportServiceTests`, `ImportOrderingTests`, `ImportProgressContractTests`, `ImportCancellationTests`, `PhotoLibraryAccessTests` |
| 22 | **Gate:** the same set of gated operations; FIFO; not reentrant; cancellable waiters; export resolves locations inside the gate | Maintenance timing, batch APIs | `OperationGateTests` (FIFO across 5 waiters; cancelling the middle one); existing `testShareResolvesLocationAfterQueuedTrashMove` and the reconcile gate test |
| 23 | **Album positions:** backfill only when positions are not unique (`createdAt`, then `uuidString`); new albums get max+1; reorder writes 0..n−1 and sets Manual | Albums rebuild | Existing `AlbumServiceTests` (11) |
| 24 | **Settings singleton** "primary" with the defaults in 2.14; reset recreates it | Any refactor | Existing tests plus `RawValueTests` |
| 25 | **Reset journal:** begin before any deletion, finish after the save; bootstrap completes a pending reset before opening the store | Seam S5 | `ResetJournalRecoveryTests` with an injected directory (no such test exists today) |

### 5.2 Known-answer vectors

These were computed on the audit machine with Python 3.12 `hashlib` and `hmac`, following the algorithms as read in the code. **Phase 0 must confirm that today's implementation reproduces every one before freezing it as a test.** If any value differs, stop and investigate before any crypto change.

| Vector | Inputs | Expected (hex) |
|---|---|---|
| PBKDF2-HMAC-SHA256 | password "password", salt "salt", c = 1, 32 B | `120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b` (already in `PBKDF2Tests`) |
| PBKDF2-HMAC-SHA256 | same, c = 2 | `ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43` |
| PBKDF2-HMAC-SHA256 | same, c = 4096 | `c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a` |
| PBKDF2 at production cost | password UTF-8 "246810", salt bytes `00 01 … 0f`, c = 210,000, 32 B | `e581fe63248a39519e40246e98ec3b4ed5d6f67b48978f0f47c033a97d57bd77` |
| Passcode verifier | HMAC-SHA256(key = the previous row's output, message "QuietFrame.passcode.verifier.v1") | `8c32ac2beefdc71b0f29faa3bee455ac444983541a6f49dee781f3199608e158` |
| Duplicate key | HKDF-SHA256(IKM = 32 × `0x4d`, salt empty, info "QuietFrame.deduplication-key.v1", 32 B) | `f652293b507cfed0d31d1f894b2abda89cdf26d2e6b9a3e647b1a93f0289e548` |
| Duplicate fingerprint | master 32 × `0x4d`; plaintext = 80,000 bytes, byte i = i mod 223 (the pattern used in `MediaImportServiceTests`); SHA-256(plaintext) = `8cad31fdd774475dbf5e148ae8c4013a314f5a8ba135ea2fd611c7324ff73777` | `1575423b4e930169e9eac50f066ebd6ff8b175e5105434e37654c91999ce3450` |
| File key | HKDF-SHA256(IKM = 32 × `0x4d`, salt = bytes `00 01 … 0f`, info "QuietFrame.file-key.v1", 32 B) | `fdec520f793611377d354b442053b42a9603cc047fa680fa1795b2b3c4c0828f` |

**Fixtures captured from today's code in Phase 0.** They come from a `FixtureCaptureTests` class that runs only when the test-runner environment has `QF_CAPTURE_FIXTURES=1` (passed as `TEST_RUNNER_QF_CAPTURE_FIXTURES=1` to `xcodebuild`). It writes XCTAttachments, which are exported from the CI result bundle and committed under `QuietFrameTests/Fixtures/`:

- **F1, containers** written by today's encryptor with master key 32 × `0x4d`: 1 byte; exactly 65,536 bytes with 64 KiB chunks; 180,000 bytes with 64 KiB chunks (short last chunk); 2.5 MiB with 1 MiB chunks; and one encrypted 720×540 JPEG thumbnail. Each is stored with its plaintext SHA-256.
- **F2, credentials:** the envelope JSON written by `createPasscode("246810")` under the production policy, with the recorded master key (`VaultSession.keyData()`); and the attempt-state JSON after 4 failures with a fixed clock.
- **F3, store:** an on-disk V3 store (`default.store`, `-wal`, `-shm`) holding every raw value, nil fields, album relationships, trashed items and an `ImportRecord`. V1 and V2 stores are already built inside tests from the frozen nested schemas.

### 5.3 Phase gates for data safety

- Every phase passes the whole compatibility suite with zero fixture changes. A commit that would need a fixture change is a format change and is out of scope.
- Changes to `ChunkedEncryptionService`, `PBKDF2`, `AuthenticationService`, `KeychainService`, `SecureFileStorageService`, `VaultSchema`, any `@Model` class, `AppModel`, `AppResetJournal` or the reset path need this section's suite plus a review against it.
- The V3 checksum must not change during this rebuild. If a model change ever becomes necessary, the order is:
  1. freeze today's classes as nested V3 copies;
  2. add V4 and a migration stage;
  3. add on-disk migration tests from V1, V2 and the F3 fixture.

---

## 6. Rewrite and verification strategy

### 6.1 CI is the only compiler

The development machine has no Xcode, so every change is compiled and tested in GitHub Actions. The loop for every commit:

1. Make a small, focused commit on `perf-rewrite` (imperative subject, per CLAUDE.md).
2. `git push origin perf-rewrite`. Pushes to `main` need merge approval; `perf-rewrite` can be pushed and dispatched freely.
3. Dispatch the "Build Unsigned IPA" workflow on the branch:
   `gh workflow run build-ipa.yml --ref perf-rewrite -R DHJUWIAODHOI/QuietFrame -f performance=true -f baseline_ref=perf-baseline`.
   Without `performance=true`, only the normal test, archive and IPA job runs. `workflow_dispatch` uses the workflow file as it exists on `perf-rewrite`, so the Phase 0 workflow changes take effect there before `main` sees them.
4. Follow the run with `gh run list -R DHJUWIAODHOI/QuietFrame --workflow build-ipa.yml --branch perf-rewrite` and `gh run watch <id>`. Read compile failures with `gh run view <id> --log-failed`.
5. Download results with `gh run download <id> -n QuietFrame-performance -D Artifacts/perf-<sha>` (`Artifacts/` is gitignored). Copy the medians, spread and counters into `Docs/Performance/RESULTS.md` (written per phase, from Phase 0 on).

**Before and after numbers always come from one job on one runner.** The performance job builds the baseline (tag `perf-baseline`) and the candidate (`HEAD`) side by side, then runs the performance classes in the order baseline, candidate, baseline, candidate on the same simulator. Runs on different days or different runners are never compared.

### 6.2 CI changes (Phase 0)

Commit `96ba12b` already did part of this. The benchmark classes are skipped in the regular test step and run in a separate serial `-O` step of the `build` job, which writes a summary table and keeps the log. The changes below complete it.

The `build` job (today's job, still run on every push):

- Select Xcode explicitly: `sudo xcode-select -s /Applications/Xcode_16.4.app/Contents/Developer`.
- Add `-skip-testing:QuietFrameTests/<Class>` for every performance class, to keep the 30-minute test step safe.
- Upload `xctest.log` and the `.xcresult` with `if: always()`, not only on failure.
- Add a guard step that fails if app code gains `print(`, `NSLog`, `os_log`, `Logger(`, `URLSession`, `UserDefaults` or `@AppStorage`, matched with `grep -rnE` over `QuietFrame/`.
- After archiving, write the size of `Assets.car` to `$GITHUB_STEP_SUMMARY` (P46).

The new `performance` job (`workflow_dispatch` only, `if: inputs.performance`, `timeout-minutes: 120`). Sketch:

```yaml
on:
  workflow_dispatch:
    inputs:
      performance: { type: boolean, default: false }
      baseline_ref: { type: string, default: perf-baseline }
      perf_classes: { type: string, default: "" }   # empty = all performance classes
  push:
    branches: [main]
jobs:
  performance:
    if: github.event_name == 'workflow_dispatch' && inputs.performance
    runs-on: macos-15
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - run: sudo xcode-select -s /Applications/Xcode_16.4.app/Contents/Developer
      - run: git worktree add "$RUNNER_TEMP/baseline" "${{ inputs.baseline_ref }}"
      # build-for-testing twice (candidate = ., baseline = $RUNNER_TEMP/baseline), each with its own
      # -derivedDataPath, -configuration Debug SWIFT_OPTIMIZATION_LEVEL=-O (keeps @testable and DEBUG hooks),
      # and the same ad-hoc signing flags as the test step (CODE_SIGN_IDENTITY=- ...)
      # test-without-building in order baseline, candidate, baseline, candidate with
      # -parallel-testing-enabled NO and one -only-testing:QuietFrameTests/<Class> per selected class
      # summary: grep -h "measured \[" the four logs >> $GITHUB_STEP_SUMMARY;
      #          xcrun xcresulttool export attachments --path <each .xcresult> --output-path <dir>
      - uses: actions/upload-artifact@v4
        if: always()
        with: { name: QuietFrame-performance, path: "${{ runner.temp }}/perf-*" }
```

Notes:

- **Optimization level.** `SWIFT_OPTIMIZATION_LEVEL=-O` on the Debug configuration keeps testability and the `#if DEBUG` hooks used by existing tests (`VaultOperationGate.waitingCount`) while making app-side Swift loops comparable to Release (M1). If the owner prefers, also run one round at `-Onone` for comparison.
- **iOS 17 job (optional).** A separate job runs the SwiftData correctness classes (ordering, search, filter, mutation, persistence) on an iOS 17.x simulator. Check `xcrun simctl list runtimes`; if no 17.x runtime is installed, `xcodebuild -downloadPlatform iOS -buildVersion 17.5` fetches one (multi-GB, several minutes). Without this job, M2 stays open and every IN-predicate change carries that risk.
- **Fixture capture.** A one-off dispatch runs only `FixtureCaptureTests` with `TEST_RUNNER_QF_CAPTURE_FIXTURES=1`, then exports the attachments for committing (5.2).

### 6.3 Phases

Every phase shares these exit criteria:

1. All existing tests (167 unit + 1 UI) and every test added so far pass on CI.
2. The compatibility suite (section 5) passes with no fixture changes.
3. The benchmark A/B run is recorded in `RESULTS.md`, with every deterministic target for the phase met and no timing regression on unrelated benchmarks. A change counts only if it exceeds max(10%, 3 × the A/A relative standard deviation).
4. The checklist items in section 2 that the phase touches have been re-read against the code and covered by tests; manual device checks are listed for Phase 8.
5. The guard step stays green.

**Phase 0: baseline, seams and safety net (no behaviour change)**

- **Scope:**
  - the CI changes in 6.2;
  - seams S1-S8 (7.3);
  - behaviour and compatibility tests;
  - benchmarks B1-B14 (section 7);
  - fixture capture, and confirming the known-answer vectors against today's code;
  - two A/A runs (baseline against itself) to measure the noise per test;
  - the `perf-baseline` tag.
- **Files:**
  - `.github/workflows/build-ipa.yml`;
  - `QuietFrame/App/AppDependencies.swift` (S1);
  - `QuietFrame/Features/Gallery/GalleryViewModel.swift` and `GalleryBrowser.swift` (S2, S6);
  - `QuietFrame/Features/Trash/TrashScreen.swift` and a new `Features/Trash/TrashOperationRunner.swift` (S6);
  - `QuietFrame/Features/Viewer/MediaViewer.swift`, where the permanent-delete path goes through S6;
  - `QuietFrame/Services/IncomingMediaFileStore.swift` (S4);
  - `QuietFrame/Security/AppResetJournal.swift` (S5);
  - `QuietFrameTests/{Performance,Compatibility,Legacy,Fixtures,TestSupport}/`;
  - `QuietFrameUITests/LaunchPerformanceUITests.swift`.
- **Tests to add:**
  - **Crypto and credentials:** `ContainerCompatibilityTests` (fixtures, reference decoder, structural checks, legacy ↔ new, tamper suite), `FingerprintVectorTests`, `PBKDF2VectorTests` (vectors and the differential test at 210,000), `EnvelopeFixtureTests`, `AttemptStateFixtureTests`, `LockoutScheduleTests`.
  - **Store and files:** `SchemaShapeSnapshotTests`, `V3StoreFixtureTests`, `StoreLocationTests`, `StorageLayoutTests`, `FileAttributeTests`, `RawValueTests`.
  - **Media pipeline:** `ThumbnailGeneratorTests`, `MetadataExtractionTests` (EXIF dates in the current time zone, raw versus oriented size, video transform).
  - **Queries:** `OrderingParityTests`, `FilterScopeTests`, `SearchParityTests`.
  - **Mutations:**
    - `RepositoryMutationTests`: `moveMedia` cover clearing, the trashed guard and all-or-nothing; `setAlbumCover` validation; the album bump in `setFavorite`; album name rules (case, diacritics, 80 characters).
    - `TrashRulesTests`: `emptyTrash`; the purge boundary and the 30-day default; restore after the album was deleted; rollback when a move fails.
    - `ReconcileRulesTests`: repairing a trashed item's file found in `media`; keeping thumbnails of trashed items; ignoring non-UUID files; uppercase names.
    - `StorageAnalysisRulesTests`: thumbnails including trashed items; the missing-file error.
  - **Concurrency and services:**
    - `OperationGateTests`: FIFO and cancellation.
    - `ThumbnailServiceTests`: coalescing; the generation blocks late inserts; synchronous `cachedImage`; failures.
  - **Import:** `ImportOrderingTests` (strictly increasing `importedAt`), `ImportProgressContractTests`, `ImportCancellationTests` (user cancel mid-chunk and lock rollback).
  - **Lifecycle:** `ResetJournalRecoveryTests` (with S5), `VideoPageLifecycleTests` (the ±1 window and `scenePhase`).
- **Benchmarks:** all of B1-B14, run A/A.
- **Exit criteria (in addition to the shared ones):**
  - the vectors are confirmed and frozen;
  - fixtures F1-F3 are committed;
  - the noise per benchmark is recorded;
  - `perf-baseline` is tagged.

**Phase 1: isolated quick wins, each proven byte-for-byte**

- **Scope:**
  - P14: PBKDF2 on CommonCrypto.
  - P31: crypto loop internals (single read, reused buffers, exact-size check before `reserveCapacity`).
  - P20: no fsync in `decryptFile`.
  - P17: progress throttling and the equal-value guard.
  - P08: IN-predicate fetches in `TrashService` and `moveMedia`, and the album dictionary in restore.
  - P18 (part): `exportItems` as one IN fetch, plus an aggregate capacity check.
  - P23: bulk favourite with one fetch (one save only if 6.4 approves).
  - P19: the Trash tab loads first, then purges; cancellation is silent.
  - P15: storage analysis with bulk listing, the top 20 sorted in the store, and cancellation.
  - P41: name-based listings.
  - P37: `store(plaintextData:)` for thumbnails, and per-item deletion of incoming files.
- **Files:** `PBKDF2.swift`, `ChunkedEncryptionService.swift`, `FileHandle+ExactRead.swift`, `SecureFileStorageService.swift` (plus the protocol and test doubles), `MediaImportService.swift`, `ImportViewModel.swift`, `TrashService.swift`, `VaultRepository.swift`, `GalleryViewModel.swift`, `TrashOperationRunner.swift`, `StorageAnalysisService.swift`, `StorageReconciliationService.swift` (listing call only), `MediaExportService.swift`.
- **Tests to add:**
  - the exact-size check runs before the cap (a tampered huge plaintext size gives `corruptedFile`, not `insufficientStorage`);
  - the progress contract under throttling (monotonic, final value delivered, item boundaries kept);
  - the Trash load order;
  - the IN predicates in the iOS 17 job.
- **Benchmarks:** B4 (PBKDF2, unlock), B7 (`testTemporaryDecryptedFile128MiB`), B8, B9, B11, B12, B13.
- **Exit criteria:**
  - the PBKDF2 vectors pass, and B4 PBKDF2 improves by more than the noise;
  - temp-decrypt writes are unchanged, and B7 time drops;
  - 128 MiB produces about 35 progress callbacks or fewer;
  - storage analysis makes 3 storage calls instead of 2N;
  - single-item Trash time is flat between 1k and 10k items, within noise;
  - bulk favourite makes 1 fetch (and 1 save if approved);
  - Trash items are available while an export holds the gate.

**Phase 2: thumbnail pipeline**

- **Scope:** P01, P02, P16, P30, P34, the thumbnail part of P43, and the small-decrypt lane.
- **Files:**
  - `ThumbnailService.swift` (rebuilt; same public API plus `image(for:pixelSize:)`, `evict(identifiers:)`, `prefetch`, `adopt`);
  - `MediaThumbnailView.swift`, `GalleryGridView.swift` (pixel size and prefetch window), `AlbumsScreen.swift` (`AlbumCover`), `ViewerFilmstrip.swift`;
  - `TrashOperationRunner.swift` and `MediaViewer.swift` (targeted eviction);
  - `TrashService.swift` (reports the deleted thumbnail identifiers);
  - `AppDependencies.swift` (the second crypto and storage instance).
- **Tests:**
  - `ThumbnailServiceTests`, extended: refcounted cancellation never leaks a continuation; the lock purges every tier; targeted eviction; failures remembered per generation; `adopt`.
  - The viewer flight and placeholders still receive at least a 720-px image from `cachedImage(for:)`.
- **Benchmarks:** B1, B3 (scroll, scroll-back, re-appearance), B8 (`testSmallDecryptLatencyDuringLargeDecrypt`).
- **Exit criteria:**
  - B1 first-display cost falls to the cost of drawing alone;
  - bytes per tile entry match the tile's pixel size (the Phase 2 counter in 7.5);
  - cancelled requests decrypt no more than 10 plus the in-flight limit;
  - Trash operations cause 0 re-decrypts of unrelated tiles;
  - the first frame uses the cached image.

**Phase 3: query layer, galleries and Albums**

- **Scope:** P04, P05, P11, P12 (step 1, and step 3 only if B2 needs it), P26, P27, P28, P29, the presenter part of P35, and P44 (optional).
- **Files:**
  - `GalleryViewModel.swift`, `VaultRepository.swift` (search pipeline, ordered IDs);
  - new `Persistence/VaultChangeMonitor.swift` and `Persistence/GallerySearchIndex.swift`;
  - `GalleryGridView.swift`, `GalleryBrowser.swift`, `MediaThumbnailView.swift`;
  - `ViewerZoomTransition.swift` (`MediaTileFrames` conversion);
  - `AlbumsScreen.swift` and a new `Features/Albums/AlbumsOverviewModel.swift`;
  - `TrashScreen.swift`.

  No `@Model` class is edited; `VaultAlbum.activeMediaCount` is computed and may simply stop being used.
- **Tests:**
  - ordering, search and filter parity, and `GallerySortingTests`;
  - skipped refreshes and Recently Added aging;
  - `MediaTileFrames` window frames match the old reporter's within 0.5 pt;
  - Albums counts match the old computation;
  - the cover-selection rule.
- **Benchmarks:** B2, B3, B5, B6 (`testViewerUpdate*`, for the hidden-tile decoupling).
- **Exit criteria:**
  - scrolling 5 pages of search results costs about one search;
  - an unchanged refresh fetches 0 rows;
  - B5 first-render memory and time no longer grow with N;
  - the tile-frame A/B difference in B3 is gone;
  - every parity test passes.

**Phase 4: unlock, launch and lifecycle**

- **Scope:**
  - P03: reconcile cost, plus the timing change if 6.4 approves it;
  - the unlock side of P25, and P32, P42;
  - the authentication, Keychain and shield parts of P43;
  - P45: scene-safe cleanup of incoming files;
  - the mass-deletion guard (if approved);
  - the optional early exit of gate holders after a lock;
  - explicit viewer dismissal on lock.
- **Files:** `StorageReconciliationService.swift`, `TrashService.swift` (purge early exit), `AppDependencies.swift`, `VaultLockCoordinator.swift`, `RootView.swift`, `AppModel.swift`, `AuthenticationService.swift`, `PrivacyShieldView.swift`, `MediaImportService.swift`, and the `project.pbxproj` build setting (only if the launch style is approved).
- **Tests:**
  - `ReconcileRulesTests` and `StoreLocationTests`.
  - If the timing change is approved, `VaultLockCoordinatorTests` (`testNoPasscodeMaintenanceFailureCanRetryWithoutRecovery`, `testNoPasscodeForegroundDoesNotRevokeActiveEncryption`) are updated deliberately.
  - A lifecycle-cancellation test: no stuck retry screen.
  - A bootstrap failure still reaches `migration-error`.
  - Multi-window cleanup.
- **Benchmarks:** B4, B14, B3 (first page after unlock).
- **Exit criteria:**
  - with the timing change, unlock-to-unlocked time no longer grows with N;
  - without it, reconcile's main-thread CPU (`XCTCPUMetric(limitingToCurrentThread: true)`) drops by more than the noise;
  - reconcile results on the fixture are unchanged;
  - the launch metric does not regress.

**Phase 5: viewer and video sessions**

- **Scope:** P06, P10, P24, the viewer side of P25, P33, P35, P36, and the interim fix for P07 (a viewer-level session owner, with the decrypt keyed on `shouldPrepare`).
- **Files:** `MediaViewer.swift`, `SecureMediaPage.swift`, `ViewerPhotoLoader.swift`, `ZoomablePhotoView.swift`, `ViewerChrome.swift`, `ViewerFilmstrip.swift`, `ViewerScrubber.swift`, `ViewerVideoPlayback.swift`, a new `Features/Viewer/VideoSessionController.swift`, and the presenters in `GalleryBrowser.swift` and `TrashScreen.swift`.
- **Tests:**
  - `MediaViewerPagingTests`, `ViewerVideoPlaybackTests`, `ViewerZoomGeometryTests` and the other viewer helper tests keep passing.
  - `ViewerPhotoLoaderTests` are updated deliberately for the new scheduling policy.
  - `ZoomablePhotoViewTests` gain "a same-aspect swap keeps zoom and pan".
  - New `VideoSessionController` tests: release on leaving the window, on close and on lock; never start while inactive.
- **Benchmarks:** B6, and B7 swipe, inactive and time-to-playable (still the temp-file path).
- **Exit criteria:**
  - B6 update cost is flat across 100, 1k and 10k loaded items, within noise;
  - photo-window bytes are at most one 4096 bitmap plus two screen-fit renditions;
  - A→B→C→B→A decrypts A once;
  - a swipe 0→1→0 decrypts once;
  - an inactive glance restarts nothing.

**Phase 6: import and export**

- **Scope:** P09, P13, the rest of P18, P21, P22, the rest of P37, P38, P39.
- **Files:** `ImportViewModel.swift`, `ImportPreviewView.swift`, `PhotoLibraryPicker.swift`, `PhotoLibraryService.swift`, `MediaMetadataService.swift`, `ThumbnailGenerator.swift`, `MediaImportService.swift`, `IncomingMediaFileStore.swift`, `MediaExportService.swift`.
- **Tests:**
  - preparation order and counts;
  - cancelling parallel preparation leaves no incoming file behind;
  - eligibility parity (the same identifiers as today's rules);
  - the duplicate pre-hash path (a size match skips encryption; trashed rows count);
  - `MetadataExtractionTests` results unchanged;
  - preview sharpness at accessibility tile sizes.
- **Benchmarks:** B9, B10, B13.
- **Exit criteria:**
  - B10 preparation time improves with peak memory inside the decode budget;
  - re-importing a duplicate encrypts 0 bytes;
  - incoming files are released per item;
  - review memory stays bounded by the preview cache.

**Phase 7: streaming video**

- **Scope:** the final fix for P07.
- **Files:** a new `Security/EncryptedAssetResourceLoader.swift` with a random-access chunk reader on `SecureFileStorageService`, `VideoSessionController.swift`, `ViewerVideoPlayback.swift` (the frame generator uses the streaming asset), `README.md` (limitation 7) and `SECURITY.md` (temp-file text).
- **Tests:**
  - random-range reads (about 1,000 ranges, including chunk boundaries) equal sequential decryption;
  - tampering with any chunk fails;
  - the exact-size check;
  - a lock during playback fails pending requests;
  - looping, seeking and generator frames on a generated clip;
  - the temp directory stays empty during playback.
- **Benchmarks:** B7 `testTimeToPlayable128MiB`, plus a 32 MiB variant.
- **Exit criteria:**
  - time-to-playable for 128 MiB and 32 MiB match within noise;
  - zero bytes are written during playback;
  - the container compatibility tests are unchanged;
  - the docs are updated.

**Phase 8: device verification and documentation**

- **Scope:**
  - Run the checks in 6.5 on devices when available: Instruments Time Profiler, Animation Hitches and Allocations with 1k and 10k items and large media; memory on a 3-4 GB iPhone and a 2 GB iPad; thermal behaviour during long imports; Face ID; file attributes; PhotoKit with real libraries; multi-window.
  - Fix the stale docs: README test counts and schema, SECURITY.md:26 and :63, PHASE_REPORT.md:114, and the CLAUDE.md status.
- **Exit criteria:** device results are recorded in `RESULTS.md`, with an issue filed for each regression.

### 6.4 Changes that need explicit sign-off

Each of these is visible, or changes behaviour in some case. None is made without approval.

1. **Maintenance after unlock (P03).** Move it after the unlock transition, and specify the failure UX. This also fixes the known issue where a maintenance failure blocks unlock.
2. **Mass-deletion guard in reconcile (3.5).** Changes behaviour only in a catastrophic case, but it is still a rule change.
3. **Atomic bulk Favorite (P23).** All or nothing instead of partial success.
4. **Album fallback cover (P05).** Any deterministic order changes some covers once. The alternative is to keep today's arbitrary rule.
5. **Launch screen (P42).** `UIUserInterfaceStyle = Dark` gives black; an Info.plist partial with a night colour set gives the exact colour.
6. **Import UX.** "Preparing N of M", candidates that stream in, and byte-weighted progress (IMP-16).
7. **Export UX (P18).** Lazy share providers, or a progress UI.
8. **Video streaming (P07).** No full plaintext copy, and playback no longer fails for lack of free space. README limitation 7 and SECURITY.md change.
9. **Viewer photo scheduling (P24).** Parallel decrypt and decode within a memory budget. The tests that encode today's policy change.
10. **Quirk fixes** (items marked Quirk in section 2, and 2.16), each decided separately:
    - the search and paging race;
    - `isSelecting` after a start-over;
    - the Vault no-results state;
    - purging on every Trash visit;
    - favouriting trashed items;
    - the passcode keypad during a biometry lockout;
    - passcode double submit;
    - `removePasscode` ordering;
    - album sort rollback;
    - the deletion dialog after a cancelled import;
    - the ENOSPC and cancellation messages;
    - uppercase identifiers;
    - multi-window cleanup and locking;
    - the two auto-lock known issues.

### 6.5 What cannot be verified without a device

- **Frame pacing:** scroll and animation hitches at 120 Hz. The simulator draws through the Mac and runs at 60 Hz, so frame counts there are only indicative.
- **Memory limits:** real memory and jetsam limits on 3-4 GB iPhones and the 2 GB iPad (6th generation), and render-server texture memory.
- **Thermal behaviour:** throttling during long imports and large decrypts.
- **Hardware decode:** HEIC and HEVC decode cost and peak memory; the simulator has no device media engine (P39, P10).
- **File protection:** the simulator does not enforce protection classes, so attributes kept across rename need a device check (SECURITY checklist).
- **Device I/O costs:** fsync and unlink on device flash, and the cost of the important-usage capacity query (P38).
- **PhotoKit:** iCloud-optimized originals, limited access, large libraries and picker IPC timing (P22, P09).
- **Biometrics:** Face ID and Touch ID flows, enrolment changes and LocalAuthentication timing.
- **iPad multi-window:** behaviour and per-window memory (P45).
- **iOS 17 SwiftData:** unverifiable if no iOS 17 runtime is available on the runner (M2).
- **Absolute timings in general:** CI numbers are only comparable with each other.

---

## 7. Benchmark plan

These tests are added in Phase 0, before any optimisation, and produce the baseline.

### 7.0 Existing benchmarks (landed during this audit)

Commit `96ba12b` added the tests below. The mapping is based on test names only; check each test's body before relying on it.

- Keep these class and test names, so the history of results stays continuous.
- Add the missing B-series measurements to these classes or to new ones, without duplicating what already exists.
- Bring each test in line with the ground rules in 7.1: deterministic counters, manual start and stop, and only APIs that survive the rebuild.

| Existing test (`6d83bea`) | Closest B-series test | Issues |
|---|---|---|
| `CryptoBenchmarks.testPasscodeKeyDerivation` | B4 `testPBKDF2_210k` | P14 |
| `CryptoBenchmarks.testEncryptingAThirtyTwoMegabyteFile` | B8 `testStore64MiB` | P31 |
| `CryptoBenchmarks.testEncryptingWhileTheMainThreadIsBusy` | B9 `testImport128MiBWithBusyMain` | P17 |
| `CryptoBenchmarks.testDecryptingSixtyThumbnails` | B8 `test1000SmallDecrypts`, B1 | P43, P16 |
| `CryptoBenchmarks.testPreparingAFortyEightMegabyteVideoForPlayback` | B7 `testTemporaryDecryptedFile128MiB` | P07, P20 |
| `ImportBenchmarks.testMakingAThumbnailForATwelveMegapixelPhoto` | B10 `testThumbnailGeneration12MP` | P39 |
| `ImportBenchmarks.testImportingEightPhotos` | B9 `testImport200SmallItemsWithThumbnails` | P29, P37 |
| `LibraryBenchmarks.testOpeningTheGallery` | B2 `testFirstPage10k` | P12 |
| `LibraryBenchmarks.testScrollingDeepIntoTheGallery` | B2 `testScrollToEnd10k`, `testDeepPage10k_*` | P12 |
| `LibraryBenchmarks.testSearchingTheGallery` | B2 `testSearchNoHits*`, `testSearchBroad10k` | P04 |
| `LibraryBenchmarks.testRefreshingFivePagesAfterTheViewerCloses` | B2 `testRefreshLoaded5kOf10k` | P11 |
| `LibraryBenchmarks.testMovingFiftyItemsToTheTrash` | B11 `testMoveOneToTrash10k`, `testMoveToTrash1000` | P08, P40 |
| `LibraryBenchmarks.testReconcilingStorageAfterUnlock` | B4 `testReconcile*` | P03 |
| `LibraryBenchmarks.testTrashTabPurgeCheck` | B11 `testPurgeNothingExpired10k` | P19 |
| `LibraryBenchmarks.testAlbumsTabCounts` | B5 (prefer the hosted `testAlbumsFirstRender10k`, because of M4) | P05 |
| `ThumbnailBenchmarks.testAPageOfThumbnailsReachesTheScreen`, `testDrawingAPageOfLoadedThumbnailsOnTheMainThread` | B1 `testFirstDisplayCostOf60Thumbnails` | P01 |
| `ThumbnailBenchmarks.testScrollingBackToEarlierThumbnails` | B1 `testThumbnailBytesAndRetention`, B3 `testScrollBackDecrypts1k` | P02 |
| `ViewerBenchmarks.testOpeningATwelveMegapixelPhoto` | B6 `testPhotoWindowBytes12MP` | P10, P24 |

Still missing after `6d83bea`, among others:

- the hosted grid, Albums and viewer tests (B3, B5, B6), which need seam S1;
- unlock-to-unlocked and the gate-holder wait (B4);
- the cancellation, eviction and first-frame counters (B1);
- the video lifecycle counters (B7);
- duplicate re-import, preparation and preview memory (B9, B10);
- the single-item, bulk-favourite and gate tests (B11);
- storage analysis (B12), export (B13) and launch (B14);
- the compatibility suite in section 5.

### 7.1 Ground rules

1. **Temporary directories only.**
   - Every class creates `FileManager.default.temporaryDirectory/QuietFramePerf-<UUID>/` with `storage/` and `cache/` inside, and removes it in class teardown.
   - `SecureFileStorageService` is always built with `baseURL`, `temporaryBaseURL` and `applyFileProtection: false`, as in the existing tests.
2. **Test stores only.** Use an in-memory `ModelContainer`, or an on-disk V3 store at a temporary URL opened with `VaultMigrationPlan` (the pattern at `GallerySortingTests.swift:383-388`). Never `default.store`.
3. **No real credentials.**
   - `VaultSession` is unlocked with a fixed 32-byte key (`0x4d` repeated).
   - Keychain access goes through `MockKeychainService`, or `KeychainService(service: "com.quietframe.vault.perf.<uuid>")`; never the production service.
   - No test calls `eraseLocalVault` or `AppResetJournal` until S5 lands.
4. **Hosted views go through seam S1** (temporary roots, `MockKeychainService`). A hosted view never uses the default `AppDependencies(modelContainer:)`.
5. **The same public behaviour before and after.** Tests call only APIs that survive the rebuild: `ThumbnailService.image(for:)` and `cachedImage(for:)`, `GalleryViewModel`, `VaultRepository.fetchMedia` and `exportItems`, `SecureFileStorageService`, `StorageReconciliationService.reconcile()`, `TrashService`, `StorageAnalysisService.analyze()`, `PBKDF2`, `AuthenticationService`, `VaultLockCoordinator`, `MediaImportService.importMedia`, `ImportViewModel.prepare`, `MediaExportService`, `ViewerPhotoLoader`, and the hosted `GalleryBrowser`, `AlbumsScreen`, `MediaViewer` and `SecureMediaPage`. A test that must use an internal type is marked **diagnostic**: it may be retired when that type disappears, but it is not rewritten to fake continuity.
6. **Deterministic data.** A seeded SplitMix64 generator, fixed sizes, and fixtures generated once per class. XCTest calls class setup on the main thread, so seeding uses `MainActor.assumeIsolated`.
7. **Measurement mechanics:**
   - `measure(metrics:options:block:)` with an explicit `iterationCount` (3 or 5) and `.manuallyStart` / `.manuallyStop`, so setup and teardown stay outside the measured span;
   - one warm-up run before `measure` wherever first-use caches would skew iteration 1;
   - async work bridged with an expectation and `wait(for:timeout:)`, which spins the main run loop so main-actor jobs still run;
   - test classes are `@MainActor`.
8. **Budgets:** each test method takes about 15 s or less on CI, including all iterations; class seeding takes about 20 s or less.
9. **Deterministic counters are the primary evidence.** They are recorded as `XCTAttachment(string: "metric:<name>=<value>")` with lifetime `.keepAlways`, and asserted only when the value is a correctness invariant or after the matching fix has landed.
10. **Timing metrics** (`XCTClockMetric`, `XCTCPUMetric`, `XCTMemoryMetric`, `XCTStorageMetric`) are secondary. They are compared as medians from the same job, using the threshold in 6.3.

### 7.2 Shared test support (`QuietFrameTests/Performance/Support/`)

- **Fixtures and data:**
  - `PerfFixture`: temporary root, unlocked session, encryption, storage (optionally wrapped by counters), and a container factory (in memory or on disk).
  - `SeededGenerator` (SplitMix64).
  - `MediaSeeder`: inserts N `VaultMedia` rows in batches of 1,000, saving inside an `autoreleasepool`. Options: fractions for trashed, favourite, photo, album membership, nil creation date, equal timestamps and tags; tricky names (IMG_2/IMG_10, Résumé/resume/RESUME, emoji, 5% nil). It returns IDs in gallery order and can create zero-length `<id>.qfe` files in `media`, `trash` and `thumbnails`.
  - `ImageFixtures`: JPEG and HEIC through `CGImageDestination` (a deterministic gradient with a low-amplitude pattern) at 720×540, 4032×3024 and 8064×6048. HEIC tests skip with `XCTSkip` when `public.heic` is not in `CGImageDestinationCopyTypeIdentifiers()`.
  - `VideoFixtures`: an `AVAssetWriter` H.264 clip (2-3 s, 1080p, `shouldOptimizeForNetworkUse = true`, so the `moov` box comes first), optionally padded with a top-level `free` box to a target size.
- **Counters:**
  - `CountingSecureFileStorage`: an actor wrapping any `SecureFileStoring`, with per-method counters and byte totals, optional synchronous latency per call (blocking, so calls cannot overlap), and an optional gate.
  - `CountingFileEncrypting`: bytes encrypted and decrypted.
  - `CountingRepository`: wraps `VaultRepositoryProtocol` to count fetch calls and rows returned (needs S2).
  - `SaveCounter`: observes `ModelContext.didSave`.
- **Harness:**
  - `HostedWindow`: a `UIWindow` on the host app's `UIWindowScene` holding a `UIHostingController`. `layoutAndCommit()` runs `view.layoutIfNeeded()` and `CATransaction.flush()`. It also provides `spin(seconds:)` and `firstScrollView()`.
  - `MetricRecorder` (attachments) and a `measureAsync` helper.

### 7.3 Seams that must land before the baseline

Each seam changes no behaviour, and is reviewed as such.

| Seam | Change | Why |
|---|---|---|
| S1 | `AppDependencies.init(modelContainer:storageBaseURL:temporaryBaseURL:keychain:applyFileProtection:)`, with defaults equal to today | Hosted views without touching real vault directories or the production Keychain service |
| S2 | `GalleryViewModel(repository: any VaultRepositoryProtocol, …)`; the protocol already declares `fetchMedia` and `setFavorite` | Deterministic row counts |
| S3 (optional) | DEBUG-only counters in `ThumbnailService` for decodes and cache insertions | Counts that storage wrappers cannot see |
| S4 | `IncomingMediaFileStore` root made injectable (default `tmp/QuietFrameIncoming`) | Preparation and import benchmarks must not race the host app's own cleanup |
| S5 | `AppResetJournal` directory made injectable (default Application Support) | Removes the known hazard of tests writing the real marker; enables `ResetJournalRecoveryTests` |
| S6 | `TrashOperationRunner` (`@MainActor`) holds the Trash tab's load sequence (purge, then refresh) and post-operation sequence (service call, cache handling, refresh), used by `TrashScreen` and by `MediaViewer`'s permanent delete. `GalleryViewModel.favoriteSelectedItems()` holds the selection-bar favourite loop | The same test can drive this behaviour before and after the change |
| S7 | Legacy oracles in the test target: `LegacyChunkedEncryptionService`, `LegacyPBKDF2`, `LegacyGalleryQuery` (copies of today's code under new names) | Byte-level and ordering parity |
| S8 | `FixtureCaptureTests` (opt-in) | Fixtures F1-F3 |

### 7.4 Benchmark classes

All classes live in `QuietFrameTests/Performance/`. "Today" values come from the code; the run confirms them.

**B1 `ThumbnailPipelinePerformanceTests`**

Fixture: 200 encrypted 720×540 JPEG thumbnails (quality 0.82) in real storage; 200 in-memory `VaultMedia` rows that reference them; `CountingSecureFileStorage`.

| Test | Measured operation | Metrics | Iter. | Counters (today) | Issues |
|---|---|---|---|---|---|
| `testFirstDisplayCostOf60Thumbnails` | Outside the measurement: a new `ThumbnailService` and `await image(for:)` × 60. Measured: assign the 60 images to 114×114-pt `UIImageView`s in a `HostedWindow`, then `layoutAndCommit()` | Clock, CPU | 5 | — | P01 |
| `testThumbnailBytesAndRetention` | Load 200 through the tile path (draw each), then probe `cachedImage(for:)` for all 200 | Memory (peak) | 3 | Bytes of one 4:3 tile bitmap (1,555,200); hits after 200 loads (≤ 43). Phase 2 adds `image(for:pixelSize:)`, and this test switches to it in the same commit; the counter is arithmetic, not timing | P02 |
| `testCancelledRequestsDoNotDecrypt` | 300 tasks request distinct items from storage that does ~1 ms of synchronous work per decrypt behind an initial gate; 290 are cancelled, then the gate opens; measured until the 10 survivors return | Clock | 5 | Decrypts completed (300) | P16 |
| `testTrashOperationEvictions` | Cache 30 vault thumbnails; restore one trashed item through `TrashOperationRunner` (S6); request the 30 again. Also purge a trashed item whose thumbnail is cached | — | 1 | Re-decrypts after restore (30); purged item still cached (yes) | P30 |
| `testFirstFrameUsesCachedImage` (diagnostic) | Seed the cache; host one `MediaThumbnailView`; one layout pass without spinning the run loop; sample a pixel 20% in from the top-left | — | 1 | Placeholder dusk `#1C2740` rather than the image (placeholder) | P34 |

**B2 `GalleryQueryPerformanceTests`**

Fixture: an on-disk V3 store with 10,000 items (10% trashed, 10% favourite, 70% photos, 60% in 20 albums, `importedAt` spread over 3 years with 1% equal timestamps, 10% nil creation dates, tricky names, 1% with tags), and a separate 1,000-item store with the same mix. A fresh `ModelContext(container)` is created per iteration wherever cold cost matters.

| Test | Measured operation | Metrics | Iter. | Counters (today) | Issues |
|---|---|---|---|---|---|
| `testFirstPage10k` | `GalleryViewModel(repository: VaultRepository(modelContext: fresh), query: all media).loadInitial()` | Clock, CPU | 5 | — | P12 |
| `testDeepPage10k_DateImported`, `_Name`, `_Type` | `VaultRepository.fetchMedia(query:offset: 9_000, limit: 80)` per sort | Clock | 5 | — | P12 |
| `testScrollToEnd10k` | `loadInitial()`, then `loadNextIfNeeded(currentItem: items.last)` until `!hasMore` | Clock | 3 | Pages (125); slowest page in ms | P12, P27 |
| `testRefreshLoaded5kOf10k` | Outside the measurement: page in 5,000 items. Measured: `refreshLoadedItems()` | Clock, CPU | 5 | Rows fetched (5,001), counted via S2 | P11 |
| `testSearchNoHits1k`, `testSearchNoHits10k` | `viewModel.query.searchText = "zzzz"`, then `loadInitial()` (setting `query` directly skips the debounce) | Clock, CPU, Memory | 5 / 3 | — | P04 |
| `testSearchBroad10k` | Search text = the year of the median `importedAt`; `loadInitial()` | Clock | 3 | — | P04 |
| `testSearchScroll5Pages10k` | The broad search, plus 5 × `loadNextIfNeeded` | Clock | 3 | — | P04 |
| `testRefreshWithSearch10k` | The broad search with 3 pages loaded; `refreshLoadedItems()` | Clock | 3 | — | P04, P11 |

**B3 `GalleryGridPerformanceTests`** (hosted; needs S1)

Fixture: a temporary on-disk store with 1,000 items, each with a real encrypted 720×540 thumbnail; `AppDependencies` through S1; an unlocked session. A 402×874-pt `HostedWindow` (iPhone 16 Pro) shows `NavigationStack { GalleryBrowser(title: "Vault", initialQuery: GalleryQuery(collection: .allMedia)) }` with `.modelContainer` and `.environment(dependencies)`. The first screen's thumbnails finish loading before anything is measured.

| Test | Measured operation | Metrics | Iter. | Counters (today) | Issues |
|---|---|---|---|---|---|
| `testScrollCost1k` | 40 steps of `contentOffset.y += 600` on the grid's scroll view, each followed by `layoutAndCommit()` and a 16 ms run-loop spin | Clock, CPU, Memory | 3 | Decrypts during the run | P01, P16, P26, P28 |
| `testScrollBackDecrypts1k` | Scroll down 6,000 pt, then back to the top | — | 1 | Decrypts on the way back (about the number of realized tiles) | P02 |
| `testReappearanceDecrypts` | 1024×1366 window (iPad-size grid); remove the hosting view from the window and add it back, as a tab switch does | — | 1 | Decrypts (> 0, because the visible set exceeds the cache) | P02 |
| `testPageAppendCost1k`, `5k`, `10k` (diagnostic) | `GalleryGridView` with a `GalleryViewModel`, k items loaded; one `loadNextIfNeeded` append plus `layoutAndCommit()` | Clock | 5 | — | P27 |
| `testSelectionToggleCost` (diagnostic) | 5,000 loaded; 50 × `toggleSelection` plus `layoutAndCommit()` | Clock | 3 | — | P28 |
| `testScrollCostWithoutTileFrames` (diagnostic) | `testScrollCost1k` on `GalleryGridView` with `tileFrames: nil` against `MediaTileFrames()`; the difference is the cost of the frame reporter | Clock, CPU | 3 | — | P26 |

**B4 `UnlockPathPerformanceTests`**

Fixture: on-disk stores with N = 1,000 and 10,000 items (10% trashed, none expired, all with thumbnail identifiers) and `AppSettings` (Auto-Lock 0, retention 30); real storage roots containing a zero-length `<id>.qfe` file for every reference.

| Test | Measured operation | Metrics | Iter. | Counters (today) | Issues |
|---|---|---|---|---|---|
| `testReconcile1k`, `testReconcile10k` | `StorageReconciliationService(modelContext: fresh, storage:).reconcile()`; assert the result is (0, 0, 0) | Clock, CPU, CPU (current thread), Memory | 5 | — | P03, P41 |
| `testUnlockToUnlocked10k` | `VaultLockCoordinator(authentication: MockAuthenticationService(), …, postUnlockMaintenance: { reconcile; purge })`. Outside the measurement: `lock()`. Measured: `unlock(passcode:)` until `.unlocked` | Clock | 5 | — | P03, P32 |
| `testNoPasscodeResume10k` | Mock in mode `.none`, after `initializeIfNeeded()`. Measured: `handleLifecycle(.background)` then `handleLifecycle(.active)`, until `.unlocked` | Clock | 5 | — | P03 |
| `testUnlockWaitsBehindGateHolder` | `AlbumService.deleteAlbum(id:mode: .moveMediaToTrash)` on a 1,000-member album with real files, sharing the gate; then `lock()` and `unlock(passcode:)` | — | 1 | Completion order; unlock wait in ms | P03 |
| `testPBKDF2_210k` | `PBKDF2.deriveSHA256Key(password: "246810", salt: 00…0f, iterations: 210_000)`; assert it equals the 5.2 vector | Clock, CPU | 5 | — | P14 |
| `testPasscodeUnlockProductionPolicy` | `AuthenticationService(keychain: MockKeychainService(), session: VaultSession(), policy: .production)`; `createPasscode` outside the measurement; measured: `lock()` then `unlock(passcode:)` | Clock | 5 | — | P14 |
| `testListIdentifiers10k` | `storage.allIdentifiers(location: .media)` over 10,000 files plus 50 junk names | Clock | 5 | — | P41 |
| `testBootstrapOpen10k` | Copy the 10k store to a fresh URL outside the measurement. Measured: `ModelContainer(for: Schema(versionedSchema: VaultSchemaV3.self), migrationPlan: VaultMigrationPlan.self, configurations: [...])` plus one `fetchCount` | Clock | 5 | — | P42 |

**B5 `AlbumsPerformanceTests`** (hosted; needs S1)

Fixture: an on-disk store with 10,000 items in 20 albums of 500 (10% trashed), and 20 encrypted cover thumbnails.

| Test | Measured operation | Metrics | Iter. | Issues |
|---|---|---|---|---|
| `testAlbumsFirstRender10k` | Outside the measurement: a new container on the store URL and `AppDependencies` (S1). Measured: host `NavigationStack { AlbumsScreen() }`, then the first `layoutAndCommit()` | Clock, Memory | 5 | P05 |
| `testAlbumsRenderPerSave10k` | With `AlbumsScreen` hosted and visible: 20 × (`VaultRepository.setFavorite` toggled on an album member, then `layoutAndCommit()`) | Clock, CPU | 3 | P05 |
| `testImportInsertsWithAlbumsVisible` and `testImportInsertsWithoutAlbums` | 20 × `insertImportedMedia` (fake identifiers, album assigned) plus `layoutAndCommit()`, with and without `AlbumsScreen` hosted; the difference is the observer amplification | Clock | 3 | P29 |

**B6 `ViewerPerformanceTests`**

Fixture: on-disk stores with 100, 1,000 and 10,000 items fetched in gallery order; real storage; encrypted JPEG fixtures at 4032×3024 and 8064×6048.

| Test | Measured operation | Metrics | Iter. | Counters (today) | Issues |
|---|---|---|---|---|---|
| `testViewerUpdate100`, `1k`, `10k` (hosted, S1) | A wrapper with `@State tick` renders `MediaViewer(items:initialMediaID: <middle item>, dependencies:)`. Measured: 30 × (`tick += 1`, then `layoutAndCommit()`). Each step re-creates `MediaViewer` and re-runs its body, as a page change does through the presenter today | Clock, CPU | 3 | — | P06 |
| `testPhotoWindowBytes12MP`, `48MP` | `ViewerPhotoLoader(storage:).prepare([selected, next, previous])`, waiting until all three images exist | Memory (peak), Clock | 3 | Σ `bytesPerRow × height`: 146,313,216 (12 MP) and 150,994,944 (48 MP) | P10 |
| `testSelectedPhotoBehindNeighbour48MP` | `prepare([neighbour])`; once its decrypt finishes (counted), `prepare([selected, neighbour])`; measured until `image(for: selected) != nil` | Clock | 3 | — | P24 |
| `testBackAndForthDecryptCount` | Windows for A→B→C→B→A, each waited for | — | 1 | Decrypts of A (2) | P24 |

**B7 `VideoPlaybackPerformanceTests`**

Fixture: a 128 MiB deterministic payload stored encrypted; a playable 2-s 1080p H.264 clip padded to 128 MiB and stored encrypted (`public.mpeg-4`); small unpadded clips for the lifecycle tests.

| Test | Measured operation | Metrics | Iter. | Counters (today) | Issues |
|---|---|---|---|---|---|
| `testTemporaryDecryptedFile128MiB` | `storage.temporaryDecryptedFile(...)` then `lease.cleanup()` | Clock, Storage, Memory | 5 | Bytes written (134,217,728) | P07, P20 |
| `testTimeToPlayable128MiB` | Host `SecureMediaPage(media: clip, isActive: true, shouldPrepare: true, storage:, photoLoader:, playback:, onTap: {}, onPhotoZoomChanged: { _ in })`; measured from insertion until `playback.mediaID == clip.id && playback.isReady`. `ViewerVideoPlayback.isReady` must be kept, because this test reads it | Clock | 3 | — | P07 |
| `testSwipeAwayAndBackDecryptCount` | A hosted `TabView(selection:).tabViewStyle(.page)` with 3 video `SecureMediaPage`s (`shouldPrepare` from the ±1 rule, `isActive` = selected) over counting storage; selection 0 → 1 → 0 with layout passes and short spins | — | 1 | `temporaryDecryptedFile` calls: 2 if the player survives, 3 if it is torn down | P07 |
| `testInactiveScenePhaseRestartsDecrypt` | `SecureMediaPage` with `.environment(\.scenePhase, holder.phase)`; storage adds ~500 ms (a cancellable sleep) before delegating; flip active → inactive → active during the load | — | 1 | Decrypt starts (2) | P33 |

**B8 `CryptoPerformanceTests`**

| Test | Measured operation | Metrics | Iter. | Counters (today) | Issues |
|---|---|---|---|---|---|
| `testStore64MiB` | `storage.store(plaintextURL:location: .media)` | Clock, CPU, Memory | 5 | Output size = 48 + P + 16·ceil(P/C) | P31 |
| `testDecryptData64MiB` | `storage.decryptData(maximumByteCount: 128 MiB)` | Clock, Memory (peak) | 5 | — | P31 |
| `testSmallDecryptLatencyDuringLargeDecrypt` | A detached 128 MiB `temporaryDecryptedFile` runs while `ThumbnailService.image(for:)` loads 30 thumbnails of 80 KB | Clock | 3 | p50 and maximum latency per thumbnail (`ContinuousClock`) | P31 |
| `test1000SmallDecrypts` | 1,000 sequential `decryptData` calls on 64 KB containers | Clock, CPU | 5 | — | P43 |

**B9 `ImportPerformanceTests`**

Fixture: real storage; a fresh in-memory container, `VaultRepository` and `MediaImportService` per iteration (otherwise the second iteration is a duplicate); the S4 incoming root.

| Test | Measured operation | Metrics | Iter. | Counters (today) | Issues |
|---|---|---|---|---|---|
| `testImport128MiBWithProgress` | One 128 MiB source; progress `{ value in await MainActor.run { recorder.append(value) } }` | Clock, CPU | 5 | Callbacks (130), monotonic `completedItems`, final tick present | P17 |
| `testImport128MiBWithBusyMain` | Same, plus a main-queue load: a chained `DispatchQueue.main.async` job that busy-waits 4 ms and re-enqueues itself during the import | Clock | 3 | — | P17 |
| `testImport200SmallItemsWithThumbnails` | 200 sources of 256 KiB, each with 100 KB of thumbnail JPEG data | Clock, Storage | 5 | `store` calls (400), `didSave` (202), files created under the incoming root (200) | P29, P37, P38 |
| `testReimportDuplicate64MiB` | Import once outside the measurement; measured: import the same bytes from a new file | Clock, Storage | 5 | Bytes encrypted (67,108,864), `duplicateCount` 1 | P21 |
| `testIncomingReleasedPerItem` | 5 sources in the incoming root; record file counts at each `completedItems` increment | — | 1 | 5 until the batch ends | P37 |

**B10 `ImportPreparationPerformanceTests`**

Fixture: 16 JPEGs and 4 HEICs at 4032×3024, plus 4 three-second 1080p H.264 clips. Each is wrapped in an `NSItemProvider` built with `registerFileRepresentation(forTypeIdentifier:visibility: .all)` that returns a copy, then in `PhotoLibrarySelection(itemProvider:typeIdentifier:mediaType:originalFilename:sourceLocalIdentifier: nil)`. The view model is `ImportViewModel(metadataReader: MediaMetadataService(), thumbnailGenerator: ThumbnailGenerator(), importer: stub, photoLibrary: stub)`, using the S4 incoming root.

| Test | Measured operation | Metrics | Iter. | Counters | Issues |
|---|---|---|---|---|---|
| `testPrepare24Items` | `prepare(selections:)` until `isPreparing == false` | Clock, CPU, Memory (peak) | 3 | Candidate order = selection order; failure counts; incoming files after `cleanupIfIdle()` = 0 | P09, P39 |
| `testReviewPreviewMemory60` (hosted, S1) | Prepare 60 small JPEG selections outside the measurement; host `ImportPreviewView(viewModel:dismiss:)`; measured: scroll through every row | Memory (peak, final), Clock | 3 | — | P13 |
| `testThumbnailGeneration12MP`, `48MP` | `ThumbnailGenerator().jpegThumbnail(for:mediaType: .photo, maximumPixelSize: 720)` on the JPEG fixtures (and HEIC where supported) | Clock, CPU, Memory (peak) | 5 | Longest side = 720; the output decodes | P39 |
| `PhotoEligibilityPerformanceTests` (optional, diagnostic) | Only when CI grants Photos access (`xcrun simctl privacy <device> grant photos com.quietframe.vault` before the run): seed 250 assets with `PHAssetCreationRequest` and time today's per-identifier eligibility loop | Clock | 3 | — | P22 |

**B11 `MutationPerformanceTests`**

Fixture: the 10k on-disk store. Single-item tests use `MockSecureFileStorage` seeded with matching identifiers, which isolates the metadata cost. Bulk file tests use real storage.

| Test | Measured operation | Metrics | Iter. | Counters (today) | Issues |
|---|---|---|---|---|---|
| `testMoveOneToTrash10k` | `TrashService.moveToTrash([id])`, restored outside the measurement | Clock, CPU | 5 | — | P08 |
| `testRestoreOne10k` | `restore([id])`, re-trashed outside the measurement | Clock, CPU | 5 | — | P08 |
| `testPermanentDeleteOne10k` | Insert one trashed row outside the measurement; `permanentlyDelete([id])` | Clock, CPU | 5 | — | P08 |
| `testMoveOneToAlbum10k` | `VaultRepository.moveMedia([id], toAlbumID:)`, alternating between two albums | Clock, CPU | 5 | — | P08 |
| `testBulkFavorite500of10k` | `GalleryViewModel` with 500 selected; `favoriteSelectedItems()` (S6) | Clock | 3 | `didSave` (500) | P23 |
| `testEmptyTrash1k` | 1,000 trashed rows with files, re-seeded outside the measurement; `emptyTrash()` | Clock | 3 | Delete calls (2,000) | P40 |
| `testMoveToTrash1000` | Real files; `moveToTrash` on 1,000 IDs, restored outside the measurement | Clock | 3 | — | P40 |
| `testPurgeNothingExpired10k` | 1,000 trashed rows, none expired; `purgeExpiredItems() == 0` | Clock | 5 | — | P19, P03 |
| `testPurgeExpired1k` | 1,000 expired rows with files, re-seeded outside the measurement | Clock | 3 | — | P19, P40 |
| `testExportItems1000of10k` | `VaultRepository.exportItems(ids:)` for 1,000 IDs, order preserved | Clock | 5 | — | P18 |
| `testTrashLoadWhileGateHeld` | Start `MediaExportService.prepareForSharing` for a 128 MiB item (it holds the gate); call `TrashOperationRunner.load()` (S6) | — | 1 | Trash items available before the export finishes (no); wait in ms | P19 |

**B12 `StorageAnalysisPerformanceTests`**

Fixture: in-memory stores with 1,000 and 5,000 items (10% trashed, all with thumbnails); real files of 1-64 KB; `CountingSecureFileStorage`.

| Test | Measured operation | Metrics | Iter. | Counters (today) | Issues |
|---|---|---|---|---|---|
| `testAnalyze1k`, `testAnalyze5k` | `StorageAnalysisService(modelContext:storage:).analyze()`; assert the summary equals a precomputed expected value | Clock, CPU | 5 | `fileByteCount` calls (2N) | P15 |
| `testOverlappingAnalysesAreNotDuplicated` | Start an analysis, cancel its task after about 10 items, start another | — | 1 | Total storage calls (the cancelled run keeps going) | P15 |

**B13 `ExportPerformanceTests`**

| Test | Measured operation | Metrics | Iter. | Counters (today) | Issues |
|---|---|---|---|---|---|
| `testPrepareForSharing8x16MiB` | 8 stored items of 16 MiB; `prepareForSharing`, then `lease.cleanup()` | Clock, Storage | 5 | Bytes decrypted (134,217,728) | P18, P20 |

**B14 `LaunchPerformanceUITests`** (UI test target)

| Test | Measured operation | Metrics | Iter. | Issues |
|---|---|---|---|---|
| `testColdLaunchToGate` | `measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) { XCUIApplication().launch() }`, then assert one of the gate identifiers checked in `QuietFrameUITests.swift:14`. No vault is created | Launch | 3 | P42 |

Coverage check: every issue from P01 to P43 is covered by at least one benchmark or deterministic counter, except P44 (reset; it can be covered once S5 lands) and P25's frame pacing (device only). P45 is covered by a behaviour test, and P46 by the CI byte count.

### 7.5 Baseline procedure and deterministic targets

1. Land Phase 0 (seams, tests, benchmarks, CI). Push, dispatch twice with `baseline_ref` = the same commit (A/A runs), record the median and spread per test, and tag `perf-baseline`.
2. Each later phase is dispatched with `baseline_ref=perf-baseline` (runs in the order A, B, A, B), and the summary goes into `RESULTS.md`.
3. After the baseline, changes to performance tests touch only the test target and are applied to both sides: cherry-pick onto a `perf-baseline-tests` branch and move the tag, recording the move in `RESULTS.md`.

| Deterministic counter | Today (from code) | Target | Phase |
|---|---|---|---|
| Bytes of one cached 4:3 tile bitmap (iPhone 16 Pro, Comfortable) | 1,555,200 | ≈ 623,808 | 2 |
| Decrypts completed for 300 requests with 290 cancelled | 300 | ≤ 10 + in-flight limit | 2 |
| Re-decrypts of 30 unrelated tiles after one Restore | 30 | 0 | 2 |
| Rows fetched by an unchanged refresh with 5,000 loaded | 5,001 | 0 | 3 |
| Storage calls per storage analysis (N items with thumbnails) | 2N | 3 | 1 |
| Progress callbacks for one 128 MiB import | 130 | ≤ ~35 | 1 |
| Plaintext temp files written per imported thumbnail | 1 | 0 | 1 |
| Saves for a bulk favourite of 500 items | 500 | 1 (if approved; otherwise 500 saves and 1 fetch) | 1 |
| Bytes encrypted when re-importing a 64 MiB duplicate | 67,108,864 | 0 | 6 |
| Viewer photo-window bytes, 48 MP sources | 150,994,944 | ≤ one 4096 bitmap + two screen-fit renditions | 5 |
| Decrypts of A in A→B→C→B→A | 2 | 1 | 5 |
| Video decrypts for a swipe 0→1→0 | 3 if torn down (to be measured) | 1 | 5 |
| Video decrypt starts across an inactive glance | 2 | 1 | 5 |
| Bytes written before a 128 MiB video is playable | 134,217,728 | ≈ 0 | 7 |
| Incoming files left during a 5-item import | 5 until the end | Decreases per item | 1 |
