# Performance rewrite: progress

Branch `perf-rewrite`, cut from `main` at `1c8d5d0`. `main` stays the working reference until the owner approves a
merge. The audit (architecture, feature inventory, the 46 ranked problems P01-P46, replacement architecture, data
risks and strategy) is in [AUDIT.md](AUDIT.md).

## How changes are verified

- Nothing can be built on the development machine (Windows, no Xcode). Every change is pushed to `perf-rewrite` and
  checked by CI: `gh workflow run build-ipa.yml --ref perf-rewrite -R DHJUWIAODHOI/QuietFrame`. The repository is
  public, so CI minutes are free.
- CI runs the full unit and UI suite on iOS 26.2, the SwiftData test classes again on iOS 18.5 and, in a parallel job,
  on an installed iOS 17.5 simulator (the deployment target). It then runs the benchmarks in
  `QuietFrameTests/Benchmarks/` on their own, serially, with `-O` and whole-module optimisation.
- `-f compare=true` adds a job that builds the baseline (`6d83bea`, the original app plus the first benchmarks) and HEAD
  on one runner and runs each side's own benchmarks alternately, twice each. Only numbers from the same job are
  compared; unchanged code moves by about 25-30% even there.
- Numbers come from a shared GitHub runner (Apple M1 virtual machine, 3 CPUs, 7 GB) and a simulator. Scroll hitches,
  Instruments traces, memory limits on devices, battery and thermal behaviour have not been measured: no device or
  Instruments is available.
- Every batch got an adversarial review by independent agents before CI, and their findings were checked and fixed.
- Tests and benchmarks use temporary directories and in-memory or temporary stores only, never a real vault.
- The CI simulator has very few cooperative threads. A test must never block one (for example with a semaphore inside
  an actor) to prove something runs elsewhere; two such tests starved and were removed.

## Phases

All phases are verified: every CI job passed in run 41491626842 at `9689d4d` (377 tests on iOS 26.2, the 99
SwiftData tests on iOS 18.5 and on iOS 17.5, the benchmarks, the comparison and the unsigned archive).

| Phase | Scope (audit IDs) | Main commits |
| --- | --- | --- |
| 0 | Audit, benchmarks, CI benchmark step, same-run comparison job, SwiftData jobs on iOS 18.5 and 17.5 | `96ba12b` `afd04e4` `c8fffa6` |
| 1 | Thumbnails decoded off the main thread at the size a tile fills, per-size memory cache, prefetch and cancellation, cached tiles shown at once, cheaper tile-frame tracking, targeted eviction (P01, P02, P16, P26, P34) | `f74efa0` |
| 2 | Viewer photos decoded at screen size with a sharper copy on zoom, O(1) page lookups, drags without whole-viewer re-renders (P10 in part) | `f72e4c5` |
| 3 | Video plays from the encrypted file through a private resource loader; no plaintext copy (P07, P33) | `81abc2c` |
| 4 | System PBKDF2 (P14); the vault opens before the storage check (P03) | `5f1df5b` `22a1ef8` |
| 5 | ID lookups (P08), store counts for the Albums tab, search pages from one scan, name-based listings (P41), bulk Favorite in one save (P23) | `95e9764` `16f995e` |
| 6 | Parallel import preparation with "Preparing N of M" (P09), progress that never waits for the main thread (P17), thumbnails encrypted from memory (P37) | `7e96ff3` `306b8ea` `61afc35` `95abab1` |
| 7 | Crypto runs in parallel and temporary files skip fsync (P31 in part, P20); bulk storage listings, one-hop batches and targeted eviction after Empty Trash and purges (P15 and P40 in part, P30); refresh skip, unchanged items kept, faster searches, viewer pager over IDs (P11, P27, P04, P06, P35); review previews in a bounded cache, blocking work off Swift's threads, picker checks off the main thread, deletes off the main thread (P13, P39, P22, P37); exact-seek chase and kept frame strips (P36); Albums cover and sort once per render, counts only while visible (P05, P29); reconcile in batches that yield and stop on lock (rest of P03); search snapshots never kept while locked | `faf547b` to `9689d4d` |

Phase 7 was implemented by seven agents in separate worktrees, merged, reviewed by eight more, and fixed before CI.
The review caught a crash risk (seeking with a completion before a video is ready), a privacy gap (a search finishing
after the lock could store its text again) and three refresh tests that could not fail; all are fixed.

## Behaviour changes approved by the owner (2026-11-02)

1. Unlock opens the vault first; the storage check runs right after and a failure no longer blocks unlock.
2. Videos play straight from the encrypted file; Share and Save to Photos still use temporary copies.
3. Bulk Favorite saves once, all or nothing.
4. Import preparation runs a few items at once and shows "Preparing N of M".

Nothing else visible changed.

## Not done

Needs the owner's sign-off (AUDIT.md 6.4 or a visible change):

- the mass-deletion guard in reconcile and the album fallback cover order;
- the launch screen colour and the rest of P42;
- export UX (P18);
- parallel viewer decode (P24) and dropping viewer copies on memory warnings (rest of P10);
- look-ahead paging (P12) and loading Trash before its purge (P19);
- hashing before encrypting to catch duplicates early (P21), which changes per-item progress;
- batching free-space checks (P38, pinned by a test);
- the quirk fixes listed in 6.4, including both auto-lock known issues and iPad multi-window cleanup (P45).

Skipped as unmeasurable without a device, negligible, or too risky for the gain: P25, P28, P32, P43 and P44.
P46 (SVG app icon) does not apply, because the app is not published.

## Tests

376 unit tests in 47 files and 1 UI test (the original app had 167 in 25), plus 49 benchmarks in 11 classes.
New coverage includes:

- PBKDF2 against independent vectors, and the container format against vectors built with CryptoKit alone;
- tampering and truncation, revocation on lock including parallel decrypts, and streaming through AVFoundation;
- library queries, and search parity across locales and time zones;
- refresh skips, thumbnails, the viewer loader, scrubbing and frame strips;
- import preparation, progress, previews and cleanup;
- batch storage operations and reconcile batching.

Still uncovered: reset-journal recovery and biometrics. On iOS 17, a test must never insert both ends of a new
relationship; insert and save one side first, or SwiftData traps with "Duplicate registration attempt".

## Results

### Same-run comparison

CI run 41491626842: `6d83bea` (original app) against `9689d4d`, one runner, each side twice in alternation, ten
iterations per side. Seconds. Each side runs its own benchmark code.

| Benchmark | Before | After | Change |
| --- | --- | --- | --- |
| Passcode key derivation (210,000 iterations) | 0.759 | 0.059 | 13x faster |
| 5,000 items: refresh after closing the viewer, nothing changed | 0.038 | 0.0005 | skipped |
| 5,000 items: move 50 to Trash | 0.377 | 0.071 | 5.3x faster |
| Encrypt 32 MiB while the main thread is busy, with import progress | 0.121 | 0.063 | 1.9x faster |
| Draw 48 newly loaded thumbnails on the main thread | 0.279 | 0.126 | 2.2x less main-thread time |
| A page of 48 thumbnails reaches the screen | 0.286 | 0.208 | 1.4x faster |
| Scroll back to the first 48 of 160 thumbnails | 0.267 | 0.194 | 1.4x faster |
| Import eight 12 MP photos | 0.143 | 0.096 | 1.5x faster; noisy |
| Decrypt 60 thumbnails one after another | 0.061 | 0.020 | about 1.5x on the steadier runs; one baseline run had 58% deviation |

The old method replicated inside the new build, against the new one (no baseline counterpart exists):

| Benchmark | Old | New | Change |
| --- | --- | --- | --- |
| 5,000 items: storage analysis, one call per file vs. one listing per location | 3.200 | 0.576 | 5.6x faster |
| 5,000 items: longest main-thread wait as reconcile starts, one fetch vs. batches | 0.462 | 0.040 | 11.5x shorter |
| 5,000 items: five pages of one search, a scan per page vs. one scan | 1.470 | 0.322 | 4.6x faster |
| 5,000 items: Albums tab counts, old queries vs. store counts | 0.245 | 0.065 | 3.8x faster |
| 60 thumbnail decrypts, one after another vs. all at once | 0.020 | 0.012 | 1.7x faster |
| Returning to a video: build its frame strip vs. the kept strip | 0.210 | 0.0005 | instant |
| Move 1,000 files, one call each vs. one batch | 0.363 | 0.312 | 1.2x faster |

Within the noise: encrypting 32 MiB, a new search's first page (0.313 vs. 0.279), opening the gallery, deep paging,
the Trash purge check, making one thumbnail, and decrypting a 48 MiB video for sharing. A full-size 12 MP decode
(0.085 vs. 0.091) is unchanged code; the app now decodes that size only when a photo is zoomed. Reconcile's total time
is unchanged or up to 15% longer (0.44 vs. 0.51) in exchange for never blocking the main thread for more than one
batch. The original Albums benchmark used the warm shared context (1.64 s) and is not comparable with the rows above.

Computed from the code, not measured:

- A 12 MP photo held by the viewer is 7.8 MB at screen size (1608x1206 on an iPhone 16 Pro), down from 48.8 MB at the
  old 4096 px. The viewer holds up to three.
- A grid thumbnail for an iPhone 16 Pro Comfortable tile is 512x384 (786 KB), down from 720x540 (1.56 MB), so the
  96 MiB cache holds about 120 instead of 43.
- Import review previews are decoded at tile size for the tiles on screen, in a 64 MiB cache (32 MiB below 4 GB).
  They were 1.56 MB bitmaps held for every candidate until the import ended, which is about 390 MB for 250 items.
  Measured in the new build, preparing 24 photos with the review's first screen leaves about 3.6 MB resident.
- Video playback writes no plaintext and needs no free space; the old path decrypted the whole file to disk, again on
  every visit.

The first baseline run (41375230861) and the earlier comparisons are in this file's git history.

## Decisions

- Keep SwiftUI, SwiftData, the container format, the Keychain layout and every versioned identifier. The rewrite
  replaces hot paths, not the stack. No schema change; the V3 checksum is unchanged.
- Decoded thumbnails, previews and viewer photos live only in memory and are dropped when the vault locks; thumbnails
  stay encrypted on disk and import thumbnails are encrypted straight from memory.
- PBKDF2 uses CommonCrypto, pinned to independent vectors and to the previous loop at full cost.
- `ChunkedEncryptionService` keeps only immutable state, so its methods are `nonisolated` and reads run in parallel;
  lock still stops every operation at its next chunk.
- Library change detection uses the in-app `LibraryChangeCounter` plus store fingerprints, not
  `ModelContext.didSave`, which may not be posted on iOS 17. Every save that changes media or albums must record a
  change, or a skipped refresh shows stale data.
- Search snapshots are kept only while the vault is unlocked.
- The app is for personal use, so App Store-only work is out of scope.
