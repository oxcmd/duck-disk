# Duck Disk 1.1 review (v1.0.0..v1.1.1, Sources)

## Code Review Summary

### Scope
- Files: 18 changed under `Sources/` (+952 / -41). New: `DuckDiskCore/ScanIndex.swift`, `DuckDiskCore/Treemap.swift`, `DuckDisk/Components/TreemapView.swift`. Changed: `Classifier`, `CleanupCategory`, `AppInventory`, `ScanTree`, `DiskScanner`, `AppModel`, `InspectorView`, `SpaceRoom`, `FindRoom`, `ApplicationsRoom`, `SettingsView`, `Theme`, `DevSnapshots`, checks.
- Focus: the 1.1 diff, checked against the product invariants in the brief. 1.0 findings were only re-checked where the new code touches them.
- Method: read the code, then ran checks. Each check was a scratch `swiftc -O` program built over `Sources/DuckDiskCore/*.swift`. Real trees used: `/Library/Developer/CommandLineTools` (119k files), `/System/Library` (297k files), `/usr` and `/Applications/Utilities`. Synthetic trees and fixtures were built in the scratchpad. All scratch files have been removed.
- Baseline: `swift build --product DuckDiskChecks && ./.build/debug/DuckDiskChecks` passes 119 checks.
- Scout findings: `ScanIndex.load` runs at every launch from `AppModel.init`. `ItemRef.size` does a linear name lookup. The AI stray-file walk includes `~/Library`. Clear Cache takes everything of kind "Web storage" and "Web data".

### Overall Assessment
The core of each feature mostly holds up:
- The squarify layout is correct.
- Removals still go only through `TrashService` and `SafetyGuard`. The one new direct deletion removes only Duck Disk's own Index folder.
- `removingOverlaps` stops double counting between categories.
- Saving and searching the index while items are being removed did not fail under stress.

Two verified defects break the brief's invariants:
1. A corrupt index file crashes the app on every launch.
2. A quadratic sort runs on the main thread, and 1.1 now reaches it from the Inspector and from Treemap navigation. It freezes the app for about 11 s on a real folder.

Separately, the AI models and Clear Cache lists include files that hold settings or sign-in state.

---

### Critical Issues
None found.

### High Priority

**H1. A corrupt index makes Duck Disk crash on every launch.** File: `Sources/DuckDiskCore/ScanIndex.swift:77-81` (also `ScanTree.swift:199-201` through `rollUp` at line 90)
- `load` adds each stored file size into `node.size` with checked `+=`. It never checks that the size is in range, and the file has no checksum.
- Many bit flips in the LZ4 stream still decode to a valid structure but contain absurd sizes. The overflow then traps.
- `AppModel.init` calls `loadIndex()` (`AppModel.swift:158`). The setting is on by default, so the trap happens at every launch, within milliseconds, before the user can turn the setting off.
- The only way out is to delete `~/Library/Application Support/Duck Disk/Index` by hand.
- Evidence:
  - I flipped random bits in a real 6,875-byte index of `/Library/Developer/CommandLineTools/usr/share` and loaded it. The `-O` and `-Onone` builds both exited with 133 (SIGTRAP).
  - Decoding the crashing file showed file sizes of 4,745,146,572,201,848,832 and an overflow when adding them.
  - Over 5,000 single-bit flips: 3,027 decoded into a tree, 146 would overflow (≈3% of all flips), and 28 produced negative sizes.
  - Truncated files (200 cut points), huge directory or file counts (`UInt32.max`), a wrong version and garbage all returned nil safely.
- Fix:
  - In `load`, reject `size < 0`.
  - Keep a running total with `addingReportingOverflow` and `return nil` on overflow. All sizes are then non-negative and the grand total fits, so no partial sum in `rollUp` can overflow.
  - Accept parent index -1 only for record 0.
  - Reject the file when `rootPath != PathFormat.realPath(root)`.
  - Optionally store a CRC32 or SHA-256 of the raw payload in the header and check it before parsing.
  - Add a check that writes a valid index with one size set to `Int64.max` and expects nil.

**H2. A quadratic `sortedChildren` now runs on the main thread from the Inspector and Treemap navigation (about 11 s on a real folder).** Files: `Sources/DuckDiskCore/ScanTree.swift:86-92` (root cause), `Sources/DuckDisk/Components/InspectorView.swift:85` (new caller), `Sources/DuckDisk/Rooms/SpaceRoom.swift:90-92` (now also reached in Treemap mode)
- `sortedChildren` sorts `ItemRef`s with `$0.size > $1.size`. For files, `ItemRef.size` goes through `file`, which calls `dir.fileIndex(named:)`, which scans the whole file list by name. So each comparison is O(n) and the sort is O(n² log n).
- 1.1 calls it in two new places:
  - inside the `InspectorView` body ("Largest inside"), for any inspected folder from Space, Treemap, Find or Cleanup;
  - from Treemap mode, through SpaceRoom's `rows` task. That task runs whatever the mode, so double-clicking a folder in the treemap still builds the Folders list.
- Measured with real file names:
  - `/Library/Developer/CommandLineTools/SDKs/MacOSX26.0.sdk/usr/share/man/man3` (11,523 files) took 10.7–11.9 s.
  - Synthetic folders: 1k files 2 ms, 5k files 117 ms, 20k files 3.6 s.
  - The Inspector body runs at least twice per selection (first render, then when `details` loads). Clicking one large folder therefore freezes the UI for over 20 s.
  - The Folders-mode path predates 1.1, but the 1.0 review did not report it.
- Fix: sort on sizes collected once. I checked this version: it gives the same order in 0.8 ms on man3.
  ```swift
  public var sortedChildren: [ItemRef] {
      var pairs: [(ItemRef, Int64)] = []
      pairs.reserveCapacity(subdirs.count + files.count)
      for d in subdirs where !d.isRemoved { pairs.append((ItemRef(dir: d), d.size)) }
      for f in files where !f.removed { pairs.append((ItemRef(dir: self, fileName: f.name), f.size)) }
      pairs.sort { $0.1 > $1.1 }
      return pairs.map(\.0)
  }
  ```
  - In the Inspector, compute the top 3 once per `item.path|revision` in the existing `.task`, not in `body`.
  - In SpaceRoom, skip the `rows` task when `mode != .folders`.
  - `TreemapPalette.kept` (`TreemapView.swift:264`) calls `ref.size` and `ref.mediaSize` per file cell and has the same lookup pattern. Pass the `Child.size` it already has instead.

### Medium Priority

**M1. AI models offers app settings files: Draw Things `custom_configs.json` and any GPT4All subfolder.** File: `Sources/DuckDiskCore/Classifier.swift:45-53, 223-233`
- Model folders are listed at a fixed depth, and every file and folder at that depth becomes an item. The only filter is the extension list for GPT4All files, and directories bypass it.
- Draw Things keeps its saved configurations in `~/Library/Containers/com.liuliu.draw-things/Data/Documents/Models/custom_configs.json` ([LM Studio Draw Things plugin README](https://lmstudio.ai/ceveyne/generate-image/files/README.md)).
- Fixture result: the AI models list included `custom_configs.json` (6 KB, "Draw Things", SafetyGuard allowed) and `GPT4All/someFolder` (non-model data).
- When a user ticks the "AI models" category, these go to the Trash with the models. That breaks the rule that settings are never offered.
- Fix: for single-file model folders (GPT4All, Draw Things, DiffusionBee, MacWhisper, whisper, torch), keep only files with model extensions. Examples: `gguf`, `ggml`, `bin`, `safetensors`, `ckpt`, `pt`, `pth`, `mlmodelc`, and Draw Things' `ckpt-tensordata`. Skip directories unless the folder is known to keep one model per directory (LM Studio, Jan).

**M2. The loose-model walk goes into `~/Library`: iCloud and cloud-storage files are listed but cannot be trashed, and other apps' private documents are offered.** File: `Sources/DuckDiskCore/Classifier.swift:241-256`
- The walk starts at the home folder and skips only packages and `~/.Trash`. Fixture results with a 1 MB threshold:
  - `~/Library/Mobile Documents/com~apple~CloudDocs/.../finetune.safetensors` and `~/Library/CloudStorage/Dropbox/.../lora.safetensors` are listed as AI models. `SafetyGuard` then denies both ("Holds data macOS or iCloud manages."). The Overview and Cleanup totals count bytes that can never be freed, and Trash reports a failure.
  - `~/Library/Containers/com.example.notes/Data/Documents/embedding.gguf` is listed and allowed. That is a model inside another app's private documents, and removing it can break that app.
- Every app-managed location the feature wants is already in `aiModelFolders` or `aiModelStores`.
- Fix:
  - At the home level, skip `Library` as `staleBuildFolders` already does (`Classifier.swift:197`).
  - Or, at minimum, skip `Library/Containers`, `Library/Group Containers`, `Library/Application Support`, `Library/Mobile Documents` and `Library/CloudStorage`, and drop items that fail `SafetyGuard.check`.

**M3. Clear Cache removes the app's cookie jar and WebKit website data, which is not "caches only".** Files: `Sources/DuckDiskCore/AppInventory.swift:54-55, 161-174`; tooltip at `Sources/DuckDisk/Rooms/ApplicationsRoom.swift:233`
- `cacheKinds` includes "Web storage" (`~/Library/HTTPStorages/<id>` and `<id>.binarycookies`) and "Web data" (`~/Library/WebKit/<id>`, i.e. LocalStorage and IndexedDB).
- Fixture result: Clear Cache for `com.vendor.editor` returned:
  - `WebKit/com.vendor.editor` (IndexedDB and LocalStorage);
  - `HTTPStorages/com.vendor.editor`;
  - `HTTPStorages/com.vendor.editor.binarycookies`.
- Meanwhile `Library/Cookies/<id>.binarycookies` is deliberately kept: kind "Cookies" is not in `cacheKinds`. The code treats cookies as data to keep in one folder and as cache in the other.
- Effects: the user is signed out of the app's web sessions. WKWebView-based apps can also lose settings or offline data kept in IndexedDB or LocalStorage. The tooltip promises "Settings and documents stay".
- Phase 4 of the plan lists "Web storage, Web data", so this is a product decision. Options:
  - (a) Caches and container caches only.
  - (b) Keep web data, but exclude `*.binarycookies` and `WebsiteData/{IndexedDB,LocalStorage}`, i.e. keep only cache-like subfolders such as `NetworkCache` and `CacheStorage`.
  - (c) Keep it as is, and say "you will be signed out" in the confirmation.

### Low Priority

**L1. Clear Cache trashes the container's `Data/Library/Caches` folder itself.** File: `AppInventory.swift:166-171`
- The Caches category clears the *contents* of that folder (`Classifier.swift:75-80`). `SafetyGuard` refuses the home-level `Library/Caches` with "Clear what is inside instead". The per-container folder is neither protected nor cleared from inside.
- A sandboxed app that writes into its caches path without creating the directory fails until something recreates it.
- Fix: offer the folder's children, the same way the Caches category does.

**L2. Turning off "Remember file names" can still leave an index on disk or in memory.** File: `AppModel.swift:164-180, 314-317`
- `forgetIndexes` starts a separate detached `removeAll`. It is not ordered against an in-flight `save` (from `analyse`) or `load`:
  - A save that is still running recreates the file after the deletion.
  - A load that is still running assigns `indexTree` after the toggle is off, because the completion guard does not re-check `Prefs.keepIndex`. Find then keeps "Searching the index from…".
- Related:
  - Adding a "Never scan" folder leaves its names searchable in the index until the next scan.
  - Indexes for every root ever scanned accumulate until the setting is turned off.
- Fix:
  - Run all index I/O on one serial queue.
  - Re-check `keepIndex` before writing and before assigning `indexTree`.
  - Drop `indexTree` when the exclusion list changes.

**L3. An index with a very deep folder chain overflows the stack.** File: `ScanIndex.swift:66-89`, `ScanTree.swift:63-67`
- `DirNode.path` is recursive, and `load` accepts any depth.
- Only a hand-made file can trigger this. Real scans are bounded by PATH_MAX; the deepest real tree I scanned had depth 22.
- A 100,000-level chain crashed at `ref.path` on the 8 MB main stack (exit 139). FindRoom calls `ref.path` on a detached task with a 512 KB stack, so a much shallower chain is enough there.
- Fix: track depth per node in `load` and reject anything deeper than about 1,024.

**L4. Treemap layout runs on the main thread for every size change.** File: `TreemapView.swift:53-57, 85-88`
- The `.task(id:)` key includes `Int(width)x Int(height)`, so a live window resize re-runs the full layout once per pixel step.
- Measured on a 448k-file tree combined from real folders: 15–21 ms at depth 4 and 20–74 ms at depth 8 (up to 1800×1100).
- Fix: debounce inside the task (`try await Task.sleep(for: .milliseconds(60))`, then check `Task.isCancelled`), or key the task on a coarser size.

**L5. `rebuildCategoryIndex` walks every ancestor of every item on the main thread.** File: `AppModel.swift:373-387`
- Measured: 25 ms for 5k items, 129 ms for 50k, 563 ms for 200k.
- It runs on every `setKeep` (each "keep this copy" click in Duplicates) and every `apply`.
- Fix: update `clearableInside` incrementally, or compute it only when the treemap needs it.

**L6. The saved index is freed on the main thread.** File: `AppModel.swift:314`, `165`, `178`
- `indexTree = nil` frees the index on the main thread. For 2.7M files that is about 60 ms (measured).
- Fix: release it on a utility queue, the way `resetResults` does for `tree`.

**L7. The Clear Cache quit flow relies on stale data.** File: `ApplicationsRoom.swift:228-251`
- `app.isRunning` comes from the snapshot taken when the inventory loaded. An app launched afterwards skips the quit prompt.
- After `quit()`, the confirmation appears 1.5 s later without checking that the app really quit (for example, if it is blocked on a "Save changes?" sheet).
- Fix: before asking, re-check `NSRunningApplication.runningApplications(withBundleIdentifier:)`.

---

### Edge Cases Found by Scout
- `loadIndex` from `init` turns any trap in `load` into a crash on every launch (H1).
- `ItemRef.size` for files scans the file list linearly, so any sort or loop over it is quadratic (H2, `TreemapPalette.kept`).
- The stray-file walk includes `~/Library`, while `staleBuildFolders` skips it (M2).
- Clear Cache's "Web storage" kind includes `.binarycookies` entries, because `bundleID(fromEntry:)` strips that suffix (M3).
- After a scan finishes, Find rows that came from the index briefly point into a freed index tree, so their paths shorten until the re-search finishes. This is harmless: `SafetyGuard` denies relative paths, so Trash cannot act on them.

### Verified Sound
- **Deletions:** the only new direct deletion is `ScanIndex.removeAll`, which removes `~/Library/Application Support/Duck Disk/Index` (`AppSupport.directory` + "Index"). All other removals in 1.1 (Clear Cache, treemap menu, Find on the index, Inspector) go through `askTrash` → `TrashService.trashOne` → `SafetyGuard.check`.
- **Index robustness and speed:**
  - Truncated files, huge directory or file counts, garbage and wrong versions return nil without crashing (huge `reserveCapacity` values are only reserved, not touched).
  - Index names with `..` are denied by `SafetyGuard` ("Not a plain absolute path").
  - Synthetic 2.7M-file tree: save 0.21 s, 24 MB file, load 0.25 s, +225 MB resident, search 0.09 s, `access()` filter on 1,000 hits 1 ms.
- **Concurrency:** 15 rounds on the CLT tree (119k files), each with a background `ScanIndex.save` while 800 items were removed, then `TreeSearch` on the loaded index while removing from it: no crash, and every index reloaded. `save` skips removed items and reads file lists through `tree.files(of:)`. Folder flags are written without the lock, but they are single bytes.
- **Scan generation:** the `loadIndex` completion checks `scanGeneration`, `tree == nil` and `target.path`. FindRoom re-runs its search on `revision`, filters missing files with `access()` off the main thread, and the stale-ref window is safe as noted above.
- **Squarify:**
  - 4,000 random cases (1–151 values, ratios up to 1e12, strips 2.5×1500 and 2000×3): no rect outside bounds, no overlaps, relative area error at most 4e-16, no non-finite output.
  - Hit testing (`last` cell containing the point) takes about 0.01 ms with 3.9k cells.
  - The canvas is `Equatable` on `version` and `selected`, so hovering repaints only the overlay.
  - Rooms are rebuilt through `.id(scanGeneration)`, and the layout reruns on `revision`, so cells never keep removed or stale refs.
- **AI models without double counting:**
  - `removingOverlaps` drops stray files inside model-folder items (LM Studio fixture: only the folder is listed).
  - DuplicateFinder skips hidden folders and `~/Library`, and `DuplicateSelection.covered` checks ancestors.
  - The category is in the Review group, so nothing is selected by default.
  - Packages and `~/.Trash` are skipped.
- **AI models improvement:** `.cache/lm-studio` (chat history) and `.cache/huggingface` (auth token) are no longer offered whole as Developer files, as they were in 1.0.
- **Clear Cache:** Apple apps own no data, so the button is disabled for them. A refresh (`loadApps(force: true)`) runs after the Trash step. The Settings scene receives the model environment.

### Recommended Actions
1. H1: check sizes for range and overflow in `ScanIndex.load`, check `rootPath`, add a checksum and a check for it.
2. H2: sort `sortedChildren` on sizes collected once, move "Largest inside" into a task, and gate the SpaceRoom `rows` task to Folders mode.
3. M1 and M2: add extension allowlists for model folders, and keep the stray walk out of `~/Library` or filter it with `SafetyGuard`.
4. M3: decide what Clear Cache should cover (options above). At minimum, exclude `*.binarycookies`.
5. L1–L7 as convenient. L2 and L1 are the cheapest.

### Metrics
- Type coverage: not measurable (Swift; no `Any` widening added).
- Test coverage: 119 checks pass. They do not cover a corrupt-but-decodable index, Draw Things or GPT4All non-model files, Library or iCloud stray files, or Clear Cache cookie entries.
- Linting: no linter configured; build is clean.

### Plan Follow-ups
- All four phases are implemented as written in `plans/261006-0503-duck-disk-v1-1-features/`.
- Acceptance item "nothing double-counted with Developer files" holds.
- Two other acceptance items, "Clear Cache (caches, web storage, container caches)" and "missing files are hidden", are met as specified. M3 questions the first.
- The phase 3 index promise ("a setting turns it off and removes saved indexes") has the gaps in L2.

### Unresolved Questions
- Loose `.safetensors`/`.ckpt` files under `~/Documents` or project folders may be models the user trained, which cannot be downloaded again, unlike the category text says. Should the walk be limited to known download locations, or should the item detail say "may be your own file"?
- For M3: should Clear Cache sign users out of apps? This needs a product decision.

Status: DONE_WITH_CONCERNS
Summary: Two High defects. A corrupt index crashes the app on every launch (Int64 overflow trap in ScanIndex.load), and a quadratic sort on the main thread, now reached from the Inspector and Treemap, freezes the app for about 11 s on a real 11.5k-file folder. Three Medium findings: AI models and Clear Cache offer settings files, iCloud files and cookies.
Concerns/Blockers: M3 needs a product decision because the plan lists web storage on purpose.

## Resolution (2026-10-06)

All findings are fixed. Checks went from 119 to 131 and pass; debug and release builds have no warnings.

- H1: index format version 2 ends with a SHA-256 of its contents. Loading rejects negative sizes, a running total that would overflow, any root record but the first, a stored root that differs from the requested one, unread trailing bytes, non-finite dates and nesting deeper than 2,048 levels. Version 1 files are ignored and rewritten by the next scan.
- H2: `DirNode.sortedChildren` reads each size once; 20,000 children sort well under a second in a debug build. "Largest inside" is worked out in the inspector's task, and Space only sorts its list in Folders mode.
- M1: model folders list either model folders (LM Studio, Jan) or model files and Core ML packages (GPT4All, Draw Things, DiffusionBee, MacWhisper, Whisper, PyTorch); settings and databases stay.
- M2: the loose-model search skips `~/Library` (and `.Trash` and packages). Loose files carry "check it is not your own", and the category text says so.
- M3 (user decision): two actions. Clear Cache moves only Caches and the contents of container caches. Reset Web Data moves HTTPStorages and WebKit after a sign-out warning.
- L1: container caches are cleared by their contents, not the Caches folder itself.
- L2: index save, load and delete run on one serial queue; save re-checks the setting when it runs. Find hides index results inside folders excluded after the index was made.
- L3: `DirNode.path` is iterative, and `DirNode.deinit` tears subtrees down with a loop (a 100,000-level chain is built, named and released on a background thread in the checks).
- L4: treemap layout waits 80 ms for a resize to settle.
- L5: the per-folder category totals are built only when the treemap needs them, cached per classification version.
- L6: the loaded index is released off the main thread.
- L7: running state is read live when an action starts; after asking an app to quit, Duck Disk waits up to five seconds and moves nothing if it is still running.
