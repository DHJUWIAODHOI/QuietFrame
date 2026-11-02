# Performance rewrite: progress

Branch `perf-rewrite`, cut from `main` at `1c8d5d0`. `main` stays the working reference until a merge is approved.
The audit (current architecture, feature inventory, verified performance problems, replacement architecture,
compatibility risks and strategy) is in [AUDIT.md](AUDIT.md).

## How changes are verified

- Nothing can be built on the development machine (Windows, no Xcode). Every phase is pushed to `perf-rewrite` and
  checked by CI: `gh workflow run build-ipa.yml --ref perf-rewrite -R DHJUWIAODHOI/QuietFrame`.
- CI runs the full unit and UI test suite, then the benchmarks in `QuietFrameTests/Benchmarks/` on their own:
  serially, with `-O` and whole-module optimisation, on an iPhone 16 Pro simulator. The timings go to the job
  summary and the `QuietFrame-benchmarks` artifact (kept 30 days).
- Benchmark numbers come from a shared GitHub runner and a simulator, not a device. They show relative change
  between runs on matching runner hardware (the summary records the CPU); they are not device timings. Scroll hitches,
  Instruments traces, battery and thermal behaviour have not been measured: no device or Instruments is available.
- Benchmarks use temporary directories and in-test stores only. They never touch a real vault.

## Phases

| Phase | Scope | State |
| --- | --- | --- |
| 0 | Audit, benchmarks, CI benchmark step | Done (`96ba12b`, `6d83bea`) |
| 1 | Thumbnail pipeline: off-main decode at fill size, per-size cache, prefetch, cancellation, cheaper tile-frame tracking, targeted eviction, 720 px viewer previews | Reviewed (4 lenses, 9 confirmed findings fixed); in CI |
| 2 | Viewer photos: screen-size decode, full resolution on zoom, cancellable neighbour prefetch, thumbnail preview, O(1) page lookups | Planned |
| 3 | Video: play encrypted files without a whole-file plaintext copy | Planned |
| 4 | Unlock: system PBKDF2 (byte-identical, known-answer and differential tests), then maintenance timing (needs sign-off) | PBKDF2 in CI |
| 5 | Library: fetch by IDs, counts without loading every item, search snapshot, batched saves | Planned |
| 6 | Import: coalesced progress, thumbnails encrypted from memory, parallel preparation | Planned |

## Baseline

CI run 41375230861 (commit `6d83bea`, app code identical to `1c8d5d0`), iPhone 16 Pro simulator, Xcode 16 on the
`macos-15` runner, optimised build, 5 iterations each. Average seconds, with the relative standard deviation.

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

High RSDs (thumbnails, decrypts) come from the shared runner; compare averages only when the spread allows it.

## Decisions

- Keep SwiftUI, SwiftData, the container format, the Keychain layout and every versioned identifier. The rewrite
  replaces hot paths, not the stack.
- Thumbnails stay encrypted on disk. Decoded thumbnails live only in memory, cached per 64-pixel size step, and the
  cache is still emptied whenever the vault locks.
