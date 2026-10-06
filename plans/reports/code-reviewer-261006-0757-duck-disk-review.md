# Duck Disk — Production-Readiness Review

Date: 2026-10-06 · Reviewer: code-reviewer · Mode: read-only (no source edits)

## Code Review Summary

### Scope
- Files: all of `Sources/DuckDiskCore` (19 files), `Sources/DuckDisk` (App, AppModel, ContentView, Theme, DevSnapshots, Settings, Components, 9 Rooms), `Sources/DuckDiskChecks`, `scripts/package-app.sh`, `Resources/Info.plist`
- LOC: ~6,900 Swift
- Focus: full codebase against the six product invariants, plus crashes, leaks and UX logic
- Baseline: `swift build` clean; `DuckDiskChecks` → **78 checks pass** (brief said 75). A `-strict-concurrency=complete` build shows about 20 warnings. They are mostly in lock-protected code; none flag the tree races, because the tree types are `@unchecked Sendable`.
- Empirical harnesses (scratchpad only; no project files changed). Each one compiled `Sources/DuckDiskCore/*.swift` with a small `main.swift`:
  1. **Stale `ItemRef` after the tree is released** → SIGSEGV on `ref.path`, 3/3 runs, release build, even with no heap churn. The control run, with the tree kept alive, passes.
  2. **Tree readers vs `ScanTree.remove`**: 1 background reader + writer → 40/40 rounds clean. 2 readers + writer → abort in round 1: `_ContiguousArrayStorage deallocated with non-zero retain count 2`.
  3. **Parallel `TrashService.trash` of 200 same-named files** on a scratch APFS disk image → all 200 distinct contents present in `.Trashes`. No overwrite race. The image was unmounted and deleted.
  4. **SafetyGuard probes** against a fake home (results in the High and Low sections below).
- Note: ASan deadlocks at runtime init on this macOS 26.5 / CLT combination, so the UAF was shown with a plain crash harness instead.

### Overall Assessment
The core pieces are solid:
- The scanner is well built.
- TrashService is safe under concurrency.
- Classifier-level overlap removal is correct.

The app layer has one **critical memory-safety defect**: rooms keep tree references after a rescan, and those references then point to freed memory. It also has several **duplicate-handling holes that break invariant 4** ("one copy is always kept"). Invariant 2 fails for the Photos library bundle itself. Invariant 5 is not memory-safe: the crash mechanism is reproduced, and the in-app likelihood is low but reachable. Not ready to ship until the Critical and High items are fixed.

### Invariant verdicts
| # | Invariant | Verdict |
|---|-----------|---------|
| 1 | User files are only ever trashed (via SafetyGuard) | **Holds** for user files. One caveat in M5: the compressor pre-deletes a file at its temp name without proving it created that file. |
| 2 | Protected paths can never be trashed | **Fails**: the Photos library bundle itself is allowed (H3). Non-canonical paths get past the deny lists (L1, not reachable from the UI today). |
| 3 | Cleanup totals accurate, no double counting, `apply` patches state correctly | **Partial**. Classifier totals hold (`clearable + kept = scanned` check passes). The duplicates category over-counts clones and hard links (M2), and the kept copy is not re-checked after a trash (H1). |
| 4 | Duplicates: identical content only; links and clones not waste; kept copy never trashed | Content matching and inode dedupe are correct. **Fails** on the kept copy (H1, M3), clone counting (M2) and the suggestion index (L-group). |
| 5 | Thread safety of the tree | **Fails** (H2). Reproduced crash mechanism; low in-app likelihood. |
| 6 | Scanner correctness | **Holds** (details in the Scanner section). |

---

## Critical Issues

### C1. Use-after-free: room state keeps `ItemRef`/`DirNode` alive after `resetResults()` frees the tree
- `ScanTree.swift:29` declares `unowned(unsafe) var parent`. `AppModel.resetResults()` sets `tree = nil` (`AppModel.swift:177`), which frees the root and every ancestor.
- These view-level `@State` values outlive it:
  - `CompressRoom.suggestions` (`CompressRoom.swift:15`)
  - `FindRoom.hits` and `selected` (`FindRoom.swift:11,14`)
  - `SpaceRoom.current`, `rows`, `largest` and `selected` (`SpaceRoom.swift:7-11`)
- Their next render walks `ref.path` → `parent.path` into freed memory:
  - `CompressRoom.swift:132-137`
  - `FindRoom.swift:147,162`
  - `SpaceRoom.swift:28,94,129`
- The guard `.onChange(of: model.tree === tree)` (`SpaceRoom.swift:79`) is dead code. `tree` *is* `model.tree` inside `content(tree)`, so the value is always `true`, and `current` survives rescans.
- Repro:
  - Open Compress (with suggestions) and press ⌘R or choose another drive. This crashes on the immediate re-render, before `.task` clears the list.
  - Or: Find with results, or Space drilled into a folder → ⌘R → crash when the new scan is published.
- Evidence: harness 1 (deterministic SIGSEGV).
- Fix (minimal):
  1. Add `var scanGeneration = 0` to AppModel and increment it in `resetResults()`.
  2. In `ContentView`, use `RoomView(room: model.room).id(model.scanGeneration)` so all room `@State` is discarded with the tree.
  3. Delete the dead `onChange`.
- Defense in depth, so a stale ref is never memory-unsafe again: have `ItemRef` (and `SpaceRoom.current`) keep the owning tree alive (e.g. `let owner: ScanTree`), or store paths in view state and resolve them via `model.tree?.ref(forPath:)`.

---

## High Priority

### H1. The kept duplicate can be trashed; the group then has no kept copy and every remaining copy becomes trashable
- The kept row still has "Move to Trash…" (`DuplicatesRoom.swift:147` → `Theme.swift:259-262`), and the inspector button is enabled (`InspectorView.swift:93-99`).
- After that, `apply()` prunes `g.files` but never re-validates `duplicateKeep` (`AppModel.swift:427-434`).
- `rebuildDuplicateItems()` then turns every remaining file into a duplicate item (`f.path != keep` is true for all) (`AppModel.swift:301-306`). The UI shows no "Keep" badge, and "Select All Copies" (`DuplicatesRoom.swift:53`) queues every copy, each labelled "Same as <path now in Trash>".
- Repro: in a group of 3 or more, trash the kept copy, then Select All Copies → Move.
- Fix:
  1. In `rebuildDuplicateItems()` (or `apply`), if `duplicateKeep[g.id]` is not in `g.files`, re-pick the keep with `DuplicateFinder.suggestKeep(g.files, home:)` (make it public).
  2. Disable trash actions for the kept row, or show "choose another copy to keep first".
  3. Add a last-line guard in `confirmTrash`: never send a request set that covers every remaining file of a group.

### H2. Background tree readers plus main-thread `ScanTree.remove` can free an array buffer under a reader (invariant 5)
- Mechanism: `ref.dir.files[i].flags |= FileEntry.isRemoved` (`ScanTree.swift:230`) triggers copy-on-write when a reader holds the `files` buffer. The old buffer is released. If a second reader has loaded the pointer but not yet retained it, that reader retains freed storage → abort.
- Readers run on `Task.detached`:
  - `TreeSearch.run`, `largestFiles` and `largeMedia` (`Search.swift:58,111,129`)
  - called from `FindRoom.swift:121`, `SpaceRoom.swift:77` and `CompressRoom.swift:47`
- Evidence (harness 2): one reader is safe; two readers crash immediately.
- In-app triggers:
  - Cancelled `.task`s do not stop `Task.detached`.
  - Find cancellation is checked only every 1,024 dirs.
  - The Compress "Replace originals" batch calls `model.apply` after each job (`CompressRoom.swift:187-190`). Each call bumps `revision`, which starts another `largeMedia` while the previous one is still running.
- Likelihood per event: low. Impact: hard crash.
- Minimal fix:
  1. Add a lock to `ScanTree` (`let lock = NSLock()` or `OSAllocatedUnfairLock`).
  2. In `remove()`, mutate under the lock.
  3. In the background readers (`TreeSearch.*` and `DuplicateFinder.collect`), snapshot each directory's files as `let files = tree.lock.withLock { d.files }` before iterating. This makes load+retain atomic relative to the writer.
  4. Also make `largestFiles`/`largeMedia` cancellable and drop stale results (see L7).

### H3. The Photos library bundle itself passes SafetyGuard
- `insidePhotosLibrary` only matches paths *below* `.photoslibrary/` (`SafetyGuard.swift:100-103`).
- Harness 4: `~/Pictures/Photos Library.photoslibrary` → **ALLOWED**. It is reachable from Space → Pictures → library row → "Move to Trash…".
- Inside other media libraries is also allowed (e.g. `Music Library.musiclibrary/Library.musicdb` → ALLOWED).
- Fix: deny any path that equals or lies inside a component ending in `.photoslibrary`, `.photolibrary`, `.aplibrary`, `.musiclibrary`, `.tvlibrary`, `.imovielibrary` or `.fcpbundle` (case-insensitive). Reuse the `FileKinds.mediaLibraryExtensions` list and add `musiclibrary`.

### H4. Compress silently flattens RAW/PSD/TIFF/GIF to 8-bit HEIC, and "Replace originals" is on by default
- `photoExtensions` includes `raw, cr2, cr3, nef, arw, dng, psd, gif, tif, tiff` (`DiskScanner.swift:291-293`).
- `encodePhoto` writes only image index 0 (`MediaCompressor.swift:182`), so layers, RAW sensor data, animation frames and extra pages are lost.
- `replace` defaults to `true` (`CompressRoom.swift:12`).
- `largeMedia` suggests any photo ≥ 4 MB (`Search.swift:125-131`), so RAW and PSD files rank at the top.
- The original goes to the Trash, so invariant 1 technically holds, but the loss becomes permanent once the Trash is emptied.
- Fix: limit photo compression to `jpg/jpeg/png/webp/bmp/heic`, and skip sources with `CGImageSourceGetCount > 1`. Otherwise default "Replace originals" to off for non-JPEG/PNG input.

---

## Medium Priority

### M1. A stale analysis is applied after the target changes mid-analysis
- `choose()` (`AppModel.swift:153-159`) and ⌘O stay enabled during `.analysing` (`ContentView.swift:148-173`).
- `analyse()` publishes `tree`, `classification`, `phase = .ready` and starts duplicates with no generation check after its `await` (`AppModel.swift:238-257`).
- Effects:
  - The old drive's results appear under the new target's name.
  - `phase` is `.ready` while a new scan runs.
  - The orphaned `DuplicateFinder` is never cancelled and keeps hashing.
- Fix: capture `scanGeneration` in `startScan()`. After every `await` in `startScan`/`analyse`, `guard gen == scanGeneration else { finder.cancel(); return }`.

### M2. The duplicates category counts APFS clones and shared hard links as reclaimable; `wastedBytes` goes stale
- `rebuildDuplicateItems` uses `f.size` for every non-kept copy (`AppModel.swift:303-305`).
- `makeGroup` throws away per-file clone IDs (`DuplicateFinder.swift:193-201`).
- With the fixture group {beach, beach copy, beach clone}: the header shows 3 MB wasted, but the Duplicates category, Overview "ready to clear" and Activity "freed" show 6 MB.
- `physicalCopies` is a `let`, so `wastedBytes` stays at its original value after copies are trashed.
- Fix: store `cloneID` on `DuplicateFile`. Exclude copies that share the kept file's clone ID, count each other clone class once, and compute `physicalCopies` from the remaining files.

### M3. The kept copy can sit inside another cleanup item, so two categories together trash every copy
- `rebuildDuplicateItems` checks only the *non-kept* copies against `others` (`AppModel.swift:290-306`).
- Example: keep = `~/Downloads/a.zip`, an old download that is itself in `.downloads`, and the duplicate is `~/Downloads/a (1).zip`. Ticking "Old downloads" and "Duplicates" in Overview trashes both copies. Stale `target/` folders behave the same way.
- Fix: when choosing the keep, prefer a copy not covered by another item. If every copy is covered, drop the group from the category. The H1 guard in `confirmTrash` also covers this case.

### M4. Hard-link size attribution is nondeterministic, and trashing a linked file frees nothing
- The first link the parallel scan reaches gets the bytes; the others get 0 (`DiskScanner.swift:240-245`).
- Trashing the counted link frees no space while the other link exists, yet `TrashService` reports `request.size` as freed (`TrashService.swift:48`).
- This affects pnpm store vs `node_modules`, local git clones, and similar setups. "Package cache" and stale `node_modules` totals swing between scans.
- Fix: flag files with `linkCount > 1` in `FileEntry`, show them as "shared with another link", and count 0 freed for them.

### M5. Compress queue lives in view `@State` plus an unstructured Task; a fixed temp name is pre-deleted
- Leaving the room destroys `jobs`/`running` while the Task keeps running (`CompressRoom.swift:9-13,172-199`).
- On return, the same file can be added and compressed concurrently.
- Both runs share `path + ".duckdisk-tmp." + ext`, and each `removeItem`s it first (`MediaCompressor.swift:74-75`). One run can delete the other's output after the original has already been trashed, leaving only the Trash copy.
- Line 75 also permanently deletes any pre-existing user file with that name. That is the one removal that is not provably the app's own output.
- Fix: move the queue and the in-flight path set into `AppModel`. Use a unique temp name (UUID) or `FileManager.url(for: .itemReplacementDirectory, …)`. Never pre-delete a file you did not create.

### M6. Temp-folder items are judged by the directory's own mtime and are pre-selected
- `Classifier.swift:79-82`: children of `$TMPDIR` older than 3 days go into `.logs`, which is selected by default.
- Directories with old mtimes but active contents (running apps' scratch dirs, `TemporaryItems`) get trashed.
- Fix: use the newest-descendant date (as `lastUsedDate` does), skip `com.apple.*` and `TemporaryItems`, or do not pre-select temp items.

---

## Low Priority
- **L1 — SafetyGuard accepts non-canonical paths.** Harness 4: `~/library/keychains/login.keychain-db`, `~//Library/Keychains/…`, `~/Library/./Keychains/…` and `~/LIBRARY/Mobile Documents/x` all pass (`SafetyGuard.swift:57-85`). Current callers pass canonical paths (the scan root is realpath'd; panel URLs are canonical), so this is hardening. Fix: canonicalize `realpath(parent) + "/" + leaf` and compare case-insensitively.
- **L2 — `suggestedKeep` index used after filtering** (`AppModel.swift:277-281`). The index refers to the pre-filter array, so after removed files are filtered out, the wrong copy can become the keep (e.g. the Downloads copy). Fix: resolve the keep path before filtering, and re-pick it if it was removed.
- **L3 — DuplicateFinder cancellation is per file only.** `fullHash` reads whole files (`DuplicateFinder.swift:247-261`), so a rescan keeps hashing a multi-GB file and competes with the new scan for disk. Fix: check cancellation per chunk.
- **L4 — Dev flags are active in release builds.** `scanPath`, `homeOverride` and `snapshotDir` (`AppModel.swift:133,236`, `DevSnapshots.swift:9`). `homeOverride` changes which items the Classifier pre-selects while SafetyGuard keeps using the real home. Fix: gate with `#if DEBUG`.
- **L5 — Main-thread teardown of large trees.** Freeing a multi-million-node tree on the main thread in `resetResults` (`AppModel.swift:177`) causes a UI hitch. Fix: hand the old tree to a background queue to release.
- **L6 — Dead checkboxes in Duplicates.** Copies covered by another category show a working checkbox that does nothing (`DuplicatesRoom.swift:117-121` vs `:74`).
- **L7 — Stale detached results.** `SpaceRoom.swift:77` and `CompressRoom.swift:47` assign results without `guard !Task.isCancelled`, so older results can overwrite newer ones.
- **L8 — Monitor loop never exits after release.** `MonitorModel.start` uses `[weak self]` (`MonitorRoom.swift:51-56`); if the model is released without `stop()`, the loop keeps running. Fix: `guard let self else { return }` inside the loop.
- **L9 — Snapshot comparison blocks the main thread.** `SnapshotDiff.compare` is O(n²) and runs on main via `ActivityRoom.compare()` (`Snapshot.swift:87-96`, `ActivityRoom.swift:135-141`). Comparing snapshots of different targets can freeze the UI.
- **L10 — Repeated SafetyGuard syscalls in the UI.** `TrashConfirmSheet.blocked` re-runs SafetyGuard for every item 3+ times per render (`ContentView.swift:182-246`), and each context-menu row runs it on render (`Theme.swift:262`). Also, `TrashRequest.total` double-counts nested selections (`AppModel.swift:43`).
- **L11 — Hard-link dedupe key.** `seenHardLinks` is keyed by `fileID` only (`DiskScanner.swift:240-244`), so it would collide across volumes if `crossMountPoints` were ever enabled. Fix: key by `(dev, ino)`.

## Scanner (invariant 6) — verified
- **Termination:** `pending` starts at 1 and is adjusted by `newDirs.count - 1` under one condition variable. It broadcasts when `pending == 0` or new work arrives, and waiters exit once the queue is empty and nothing is pending (`DiskScanner.swift:122-136`). No lost wake-up.
- **Cancellation:** `cancel()` broadcasts and every worker returns nil from `nextWork`. `scanSync` returns nil, and `startScan` drops the result via `self.scanner === scanner`.
- **Resource cleanup:** fds are closed by `defer` and buffers are deallocated per worker. Dataless (cloud) file materialization is disabled per worker thread.
- **Hard links:** deduped by file ID within the volume (accuracy caveat in M4).
- **Mount points:** `DIR_MNTSTATUS_MNTPOINT` skips `/System/Volumes/*`, `/Volumes/*` and `/dev`. Firmlinks (`/Users`, `/Applications`, `/Library`, `/private`, …) are walked exactly once, so a scan of `/` does not double count.

## Invariant 1 — removal inventory
- **User files:** only `FileManager.trashItem`, reached through `TrashService.trashOne` after `SafetyGuard.check` (`TrashService.swift:75-79`). Concurrency is safe (harness 3).
- **Other `removeItem` calls:**
  - Snapshot JSON: UUID-named files inside `AppSupport/Snapshots` (`Snapshot.swift:132,144`) — OK.
  - Compressor temp outputs (`MediaCompressor.swift:87,92,101,119`) — OK.
  - Pre-delete of the temp name (`MediaCompressor.swift:75`) — **not proven to be the app's own file** (M5).
  - Checks fixture: suffix precondition and pid-named temp dir (`Fixture.swift:12`, `main.swift:370`) — OK.
- **Writes:**
  - `moveItem` targets come from `uniquePath`, and `moveItem` never overwrites.
  - DevSnapshots can overwrite `<room>.png` in a user-chosen folder (dev-only, L4).

## Edge Cases Found by Scout
- Room `@State` survives `tree` replacement (C1).
- `.task(id:)` cancellation does not propagate into `Task.detached` (H2, L7).
- The kept copy can be removed from outside the Duplicates flow (H1).
- `suggestedKeep` is an index while group files get filtered (L2).
- The target can change during the `analysing` await (M1).
- Leaving the Compress room orphans an in-flight job (M5).

## Positive Observations (risk calibration only)
- TrashService's 6-wide parallel `trashItem` is safe for same-named files (200/200 preserved). Nested requests are deduplicated.
- The Classifier's `removingOverlaps` plus `keptBreakdown` keep `clearable + kept == scanned`.

## Recommended Actions
1. **C1:** reset room state per scan (`.id(scanGeneration)`) and make `ItemRef` keep its tree alive.
2. **H1 / M3:** re-pick the keep when it disappears, block trashing the kept copy, and refuse requests that cover a whole group.
3. **H2:** add a tree lock around `remove()` and around per-directory `files` snapshots in the background readers.
4. **H3:** protect media library bundles and everything inside them.
5. **H4:** restrict photo formats and default "Replace originals" to off for lossy-unsafe inputs.
6. **M1:** add generation checks in `startScan`/`analyse`.
7. **M2 / M4:** count clones and shared hard links as 0 reclaimable.
8. **M5:** move the Compress queue into `AppModel` and use unique temp files.
9. Add `DuckDiskChecks` cases:
   - keep re-pick after the kept copy is trashed
   - clone-aware duplicate item sizes
   - SafetyGuard denies `.photoslibrary` itself and non-canonical paths
   - concurrent reader + remove under the new lock

## Metrics
- Type coverage: N/A (Swift). The 6 `@unchecked Sendable` types hide the H2 race from the compiler.
- Tests: 78/78 checks pass. No coverage for the AppModel trash/duplicate state machine and no UI tests.
- Linting: no SwiftLint configured. The strict-concurrency build has about 20 warnings, most in lock-guarded code.

## Plan Follow-ups
No plan file was provided. I did not cross-check the `plans/261006-0006-duck-disk-macos-cleaner` plan.

## Unresolved Questions
1. Should media library bundles be fully untouchable (as assumed here) or trashable after an extra warning?
2. Is compressing RAW/PSD/TIFF/GIF intended at all?
3. Should temp-folder items be pre-selected in the "Safe to clear" group?

Status: DONE_WITH_CONCERNS
Summary: Full review done with empirical harnesses. There is 1 Critical issue (use-after-free from room state surviving a rescan, reproduced) and 4 High issues: kept duplicate can be trashed; tree data race reproduced; Photos library bundle passes SafetyGuard; lossy RAW/PSD replacement. TrashService concurrency and scanner correctness are verified sound.
Concerns/Blockers: Invariants 2, 4 and 5 currently fail; do not ship before C1 and H1–H4 are fixed.

## Resolution (2026-10-06)

All Critical, High and Medium findings are fixed; Low findings are fixed except L11. Checks went from 78 to 100 and pass repeatedly.

- C1: rooms are rebuilt with `.id(model.scanGeneration)` on every reset, the dead `onChange` is gone, and `DirNode.parent` is now `weak`, so a stale `ItemRef` reads a shorter path instead of freed memory (check "References outliving their tree").
- H1/M3/L2: kept-copy logic moved to `DuplicateSelection` in the core. A missing kept copy is re-picked, preferring copies no other category removes. Trash requests never include a kept copy or every copy of a set. The kept row and the inspector no longer offer Move to Trash.
- H2: `ScanTree.lock` guards `remove()`, and background readers take `tree.files(of:)` snapshots. A three-reader stress check removes every file while searching.
- H3/L1: `SafetyGuard` denies media-library bundles (whole or inside), non-canonical paths and case variants, and resolves symlinks in the parent.
- H4: only JPEG/PNG/HEIC/HEIF/WebP/BMP photos are compressed, and multi-image files are skipped.
- M1: `scanGeneration` is checked after every await before results are published.
- M2: clone ids are stored per file, `physicalCopies`/`wastedBytes` are computed live, and clones of counted copies are not offered.
- M4: a regular file with other hard links reports 0 bytes freed.
- M5: the Compress queue lives in `AppModel`, temp names are unique, and only `.duckdisk-` temp files are ever removed.
- M6: temp items are judged by the newest modification inside them.
- L3, L4, L5, L6, L7, L8, L9, L10 are fixed as suggested. L11 is not changed, because mount crossing is never enabled.
