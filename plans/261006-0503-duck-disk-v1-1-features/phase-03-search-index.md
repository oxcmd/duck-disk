---
phase: 3
title: "Saved search index"
status: completed
priority: P1
effort: "3h"
dependencies: []
---

# Phase 3: Saved search index

## Overview
Persist the scan tree's names, sizes and dates so Find works right after launch, before any scan.

## Requirements
- Core `ScanIndex.save(tree, to:)` / `load(from:)`: compact binary (dirs in pre-order with parent index, then files),
  LZFSE-compressed, magic + version header; loading rebuilds a `ScanTree` with aggregated sizes.
- Stored in `~/Library/Application Support/Duck Disk/Index/<sha256 of root path>.ddindex`; written in the
  background after every scan; the index for the current target loads at launch and on target change.
- Find uses the live tree when present, otherwise the saved index, with a note "Searching the index from <date>.
  Scan again for fresh results." Results whose file no longer exists are hidden.
- Setting "Remember file names for Find between launches" (default on); turning it off deletes saved indexes
  (Duck Disk's own files).

## Related Code Files
- Create: `Sources/DuckDiskCore/ScanIndex.swift`
- Modify: `Sources/DuckDisk/{AppModel,SettingsView}.swift`, `Sources/DuckDisk/Rooms/FindRoom.swift`, `docs/README.md`

## Success Criteria
- [x] Round trip on the fixture keeps file count, total size, hidden flags and search results.
