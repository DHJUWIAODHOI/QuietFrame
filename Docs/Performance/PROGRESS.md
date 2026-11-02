# Performance rewrite: progress

Branch `perf-rewrite`, cut from `main` at `1c8d5d0`. `main` stays the working reference until a merge is approved.
The audit (current architecture, feature inventory, verified performance problems, replacement architecture,
compatibility risks and strategy) is in [AUDIT.md](AUDIT.md).

## How changes are verified

- Nothing can be built on the development machine (Windows, no Xcode). Every phase is pushed to `perf-rewrite` and
  checked by CI: `gh workflow run build-ipa.yml --ref perf-rewrite -R DHJUWIAODHOI/QuietFrame`.
- CI runs the full unit and UI test suite on iOS 26.2, the SwiftData test classes again on iOS 18.5, and, in a
  parallel job, the SwiftData classes on an installed iOS 17.5 simulator (the deployment target). Then it runs the
  benchmarks in `QuietFrameTests/Benchmarks/` on their own: serially, with `-O` and whole-module optimisation, on an
  iPhone 16 Pro simulator. Timings go to the job summary and the `QuietFrame-benchmarks` artifact.
- For before/after numbers, dispatch with `-f compare=true`: a separate job builds the baseline (`6d83bea`, the
  original app with the benchmarks) and HEAD on one runner and runs their benchmarks alternately, twice each.
  Numbers from different runs or runners are not compared; even within one job, unchanged code moves by about
  25-30%, so only larger differences mean anything.
- Benchmark numbers come from a shared GitHub runner (Apple M1 virtual machine, 3 CPUs, 7 GB) and a simulator, not a
  device. Scroll hitches, Instruments traces, memory limits, battery and thermal behaviour have not been measured: no
  device or Instruments is available.
- Every phase gets an adversarial review by independent agents (compile, concurrency or data semantics, behaviour,
  privacy or tests) whose findings are verified before they are fixed.
- Benchmarks and tests use temporary directories and in-test stores only. They never touch a real vault.

## Phases

"Verified" means every CI job passed on the commit that contains it. The latest full pass is run 41411193189 at
`61afc35`: 249 tests on iOS 26.2 (248 unit, 1 UI), the 56 SwiftData tests on iOS 18.5 and on iOS 17.5, the
benchmarks and the unsigned archive.

| Phase | Scope (audit IDs) | Commits | State |
| --- | --- | --- | --- |
| 0 | Audit, benchmarks, CI benchmark step, same-run comparison job, SwiftData jobs on iOS 18.5 and 17.5 | `96ba12b` `6d83bea` `afd04e4` `c8fffa6` `b6a6eed` | Verified |
| 1 | Thumbnails: off-main decode at the size a tile fills, per-size memory cache, prefetch and cancellation, cached tiles shown at once, cheaper tile-frame tracking, targeted eviction, 720 px viewer previews (P01, P02, P16, P26, P30, P34) | `f74efa0` | Verified |
| 2 | Viewer photos: screen-size decode with a sharper copy on zoom, O(1) page lookups, drags and page changes without whole-viewer re-renders (P06; P10 and P35 in part) | `f72e4c5` | Verified |
| 3 | Video plays from the encrypted file; no plaintext copy (P07) | `81abc2c` | Verified |
| 4 | Unlock: system PBKDF2 (P14); the vault opens before the storage check (P03) | `5f1df5b` `22a1ef8` | Verified |
| 5 | Library: ID lookups (P08), store counts for the Albums tab (P05), search pages from one scan (P04 in part), lighter reconcile, name-based listings (P41), bulk Favorite in one save (P23) | `95e9764` `ef22709` `16f995e` | Verified |
| 6 | Import: parallel preparation with "Preparing N of M" (P09), progress that never waits for the main thread (P17), thumbnails encrypted from memory and incoming copies removed per item (P37 in part) | `7e96ff3` `306b8ea` `61afc35` | Verified |
| 7 | See "Phase 7 plan" below | — | Designed, not started |

Corrections from the completeness review: P05, P06 and P30 are only partly done. Album covers still walk
`album.media` up to four times per render, the viewer pager is still O(loaded items) per body evaluation, and Empty
Trash and purges still flush the whole thumbnail cache.

### Phase 7 plan (designed 2026-11-02, nothing implemented yet)

Fix first:

1. **Memory regression from `7e96ff3`.** Import review previews are decoded to 720 px bitmaps during preparation and
   kept until the summary: about 290-520 MB for 250 items (computed). The old code decoded lazily. Fix: a
   byte-bounded, tile-sized preview cache (P13).
2. **Search snapshot survives a lock.** `VaultRepository.searchSnapshot` keeps the typed text and the matching IDs.
   Clear it when the state leaves `.unlocked` (where `RootView` empties the thumbnail cache) and on reset.
3. **Reconcile blocks the main thread** for about 0.4 s at 5k items, 0.75 s after unlock. Fetch in batches of 500,
   sorted by id, with `Task.yield()` between batches. The gate already blocks concurrent media changes.

Then, in independent groups with disjoint files (worktrees, adversarial review, one CI run):

- **Crypto (P31 part, P20):**
  - make every `ChunkedEncryptionService` member `nonisolated` (it holds only immutable state), plus
    `SecureFileStorageService.decryptData`;
  - drop the extra copy per chunk, and reserve bounded capacity in `decryptData`;
  - remove the fsync in `decryptFile`;
  - remove the unreachable `FileEncrypting.openReader` default;
  - keep a few recent chunks in `EncryptedFileReader`.
- **Storage (P15 part, P40 part, P30):**
  - one bulk size listing per location for storage analysis;
  - one-hop batch move and delete, keeping per-item rollback;
  - targeted thumbnail eviction after Empty Trash and purges;
  - remove the `SecureFileStoring.openEncryptedReader` default and give every test double an explicit stub;
  - a pinning test for the per-item free-space check (P38 stays as is).
- **Gallery (P11, P27, P04 part, P06, P35):**
  - skip a refresh when the change counter, query, locale, time zone and calendar are unchanged (Recently Added
    always refreshes), and don't reassign unchanged items;
  - reuse the offset-0 search snapshot, and memoize dates per day while searching;
  - pass ID arrays to the viewer pager, move the viewer-wide albums query, and stop `MediaPositionIndex` rebuilding
    on every miss.
- **Import (P13, P39, P22, P37 part):**
  - the preview cache;
  - blocking ImageIO work on a dispatch queue, and `image(at:)` for video;
  - picker eligibility checks off the main thread with identical results;
  - unlinks off the main thread, and the batch backstop removes only unprocessed sources;
  - `LatestValueRelay` finishes its stream in `deinit`;
  - restore do/catch where `try?` replaced it.
- **Video (P36):**
  - one exact seek in flight, plus the newest pending position (no tolerance, so the frames shown stay exact);
  - the frame strip generated in one batch and kept per media;
  - remove the unused `UniformTypeIdentifiers` import in `SecureMediaPage`.
- **Albums (P05, P29):**
  - evaluate the cover once per render, and sort once;
  - refresh counts only while the screen is visible;
  - move `VaultAlbum.activeMediaCount` (no app caller) into a test extension.
- **Last:** prune the comments the rewrite added (app comment lines grew from 123 to 224, against CLAUDE.md), and add
  any new benchmark classes to `BENCHMARK_CLASSES` in the workflow.

Left out because they change visible behaviour (need sign-off): P12 look-ahead, seek tolerance while scrubbing,
re-ordering ties in the storage top 20, batching free-space checks (P38), and loading Trash before the purge (P19).

Test fixes on the way: two tests crashed on iOS 17 because their setup inserted both ends of a new relationship,
which iOS 17's SwiftData registers twice; the test files were unchanged from `main`, so the crash predates the
rewrite (`136dd47`). A thumbnail test timed out once during a long simulator stall; its waits are now 30 s
(`a237794`).

Needs the owner's sign-off before it can be done (AUDIT.md 6.4): the mass-deletion guard, the album fallback cover
order, the launch screen colour, export UX (P18), parallel viewer decode (P24) and the listed quirk fixes.

## Behaviour changes approved by the owner (2026-11-02)

1. Unlock opens the vault first; the storage check runs right after and a failure no longer blocks unlock.
2. Videos play straight from the encrypted file; Share and Save to Photos still use temporary copies.
3. Bulk Favorite saves once, all or nothing.
4. Import preparation runs a few items at once and shows "Preparing N of M".

## Tests

248 unit tests in 32 files plus 1 UI test (the original app had 167 in 25 files), and 26 benchmarks in 5 classes
that run in their own CI step. New coverage includes thumbnail loading and caching, the viewer loader, iterated
PBKDF2 against independent vectors, container tampering and truncation, encrypted streaming end to end through
AVFoundation, library queries, unlock maintenance ordering, import preparation and progress, and per-item import
cleanup. Still uncovered: reset-journal recovery, metadata extraction and biometrics.

## Results

### Same-run comparison

CI run 41414595318, job "Compare benchmarks with a baseline": `6d83bea` (original app code) against `95abab1`
(phases 1-6), one runner, each side twice in alternation, averages of 10 iterations. Seconds. Each side builds and runs
its own benchmark code, so a benchmark that copies the app's behaviour (such as progress delivery) measures each
version's own behaviour. "Same build" rows compare the old method, replicated, with the new one inside the candidate
build, because the original benchmark measured something different.

| Benchmark | Before | After | Change |
| --- | --- | --- | --- |
| Passcode key derivation (210,000 iterations) | 0.637 | 0.056 | 11x faster |
| 5,000 items: move 50 to Trash | 0.362 | 0.084 | 4.3x faster |
| 5,000 items: five pages of one search (same build; old cost reproduced by saving between pages) | 1.642 | 0.308 | 5.3x faster |
| 5,000 items: Albums tab counts (same build, fresh context: old queries vs. store counts) | 0.301 | 0.079 | 3.8x faster |
| Encrypt 32 MiB while the main thread is busy, with import progress delivery | 0.137 | 0.081 | 1.7x faster |
| Draw 48 newly loaded thumbnails on the main thread | 0.244 | 0.121 | 2x less main-thread time |
| Scroll back to the first 48 of 160 thumbnails | 0.281 | 0.170 | 1.7x faster |
| A page of 48 thumbnails reaches the screen | 0.287 | 0.204 | 1.4x, at the edge of the noise |
| Open a 12 MP photo (old 4096 px decode vs. screen-size decode) | 0.087 | 0.077 | within noise here; 1.7x in run 41405788548 |

Within the noise in this run: decrypting 60 thumbnails, encrypting 32 MiB, importing eight photos, making one
thumbnail, opening the gallery, paging deep, refreshing after the viewer, reconciling (no longer on the unlock path)
and the Trash purge check (a few milliseconds either way). Three rows came out slower; none is a code regression:

- First search page, 0.302 vs. 0.413: one candidate run was slow throughout (0.48-0.62 per iteration); the other
  matched the baseline (0.30 vs. 0.28-0.32), as did run 41405788548 (0.291 vs. 0.285).
- Full-size 12 MP decode, 0.087 vs. 0.099: same decode options, priority and entry point on both sides. The app no
  longer decodes at this size until the photo is zoomed.
- Decrypting a 48 MiB video to a temporary file, 0.058 vs. 0.074: the code is unchanged on this path, which now
  serves only Share and Save to Photos. The difference is most likely the fsync of 48 MiB right after the new 48 MiB
  streaming benchmark; P20 removes that fsync.

The original benchmark for Albums counts used the warm shared context and took 1.26 s at the baseline; that figure
is not comparable with the fresh-context rows above.

Deterministic effects, computed from the code rather than measured:

- A decoded 12 MP photo held by the viewer: 48.8 MB at the old 4096 px (4032x3024) vs. 7.8 MB at screen size
  (1608x1206 on an iPhone 16 Pro); the viewer holds up to three.
- A grid thumbnail filling an iPhone 16 Pro Comfortable tile: 512x384 (786 KB) instead of 720x540 (1.56 MB), so the
  96 MiB cache (64 MiB before, on devices with at least 4 GB) holds about 120 instead of 43.
- Video playback writes no plaintext copy and needs no free space; the old path decrypted the whole file to disk
  first, again on every visit.

### Baseline

CI run 41375230861 (commit `6d83bea`, app code identical to `1c8d5d0`), 5 iterations each. Average seconds, with the
relative standard deviation. Kept for reference; compare only within the same run.

| Benchmark | Average (s) | RSD |
| --- | --- | --- |
| Passcode key derivation (210,000 iterations) | 0.632 | 6% |
| Encrypt a 32 MiB file | 0.069 | 9% |
| Encrypt 32 MiB while the main thread is busy | 0.116 | 17% |
| Decrypt 60 thumbnails | 0.043 | 69% |
| Prepare a 48 MiB video for playback (decrypt to a temp file) | 0.062 | 12% |
| A page of 48 thumbnails reaches the screen | 0.473 | 46% |
| Draw 48 loaded thumbnails on the main thread | 0.197 | 20% |
| Scroll back to the first 48 of 160 thumbnails | 0.232 | 36% |
| Open a 12 MP photo in the viewer | 0.092 | 25% |
| Make a thumbnail for a 12 MP photo | 0.043 | 22% |
| Import eight 12 MP photos | 0.120 | 29% |
| 5,000 items: open the gallery (first page) | 0.006 | 4% |
| 5,000 items: page at offset 2,400 | 0.011 | 8% |
| 5,000 items: search, first page | 0.278 | 8% |
| 5,000 items: refresh 400 loaded items after the viewer closes | 0.021 | 6% |
| 5,000 items: move 50 to Trash | 0.270 | 5% |
| 5,000 items: reconcile storage after unlock | 0.393 | 6% |
| 5,000 items: Trash tab purge check | 0.010 | 18% |
| 5,000 items: Albums tab counts (one body evaluation) | 0.768 | 22% |

## Decisions

- Keep SwiftUI, SwiftData, the container format, the Keychain layout and every versioned identifier. The rewrite
  replaces hot paths, not the stack. No schema change; the V3 checksum is unchanged.
- Thumbnails stay encrypted on disk. Decoded thumbnails live only in memory, cached per 64-pixel size step, and the
  cache is still emptied whenever the vault locks.
- PBKDF2 uses CommonCrypto; its output is pinned to vectors computed independently with Python's hashlib and to the
  previous CryptoKit loop, including one full 210,000-iteration comparison.
- Change detection for the Albums counts and search pages uses an in-app change counter plus store fingerprints, not
  `ModelContext.didSave`, which may not be posted on iOS 17.
