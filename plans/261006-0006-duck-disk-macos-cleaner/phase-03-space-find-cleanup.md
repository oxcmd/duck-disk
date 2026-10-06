---
phase: 3
title: "Space, Find, Cleanup, Inspector"
status: completed
priority: P1
effort: "1d"
dependencies: [2]
---

# Phase 3: Space, Find, Cleanup, Inspector

## Overview
Three tree-driven rooms plus a shared inspector panel.

## Requirements
- Space: drill-down list (breadcrumb, children sorted by size, proportional bar, kind icon), toggle
  "Folders / Largest files" (top 200 files across tree), context menu Reveal / Quick Look / Move to Trash.
- Find: search field, results as you type over scan index incl. hidden; debounce 120 ms; cancellable background
  search split across cores; ASCII case-fold fast path on UTF-8 bytes; filters kind (any/folders/files/media)
  and min size; results sorted by size, capped 1000.
- Cleanup: sections per category with total + checkbox, expandable items (name, path, size, last modified),
  shared selection with Overview, "Move selected to Trash".
- Inspector (`.inspector`): icon, name, path, size, items, modified/accessed, category + reason text,
  actions Reveal in Finder / Quick Look / Move to Trash (disabled when SafetyGuard denies).
- Tree patching after trash: remove node, subtract sizes up to root, bump revision.

## Related Code Files
- Create: `Sources/DuckDiskCore/{Search,LargestFiles}.swift`,
  `Sources/DuckDisk/Rooms/{SpaceRoom,FindRoom,CleanupRoom}.swift`, `Sources/DuckDisk/Components/InspectorView.swift`

## Success Criteria
- [x] Find returns results <200 ms on 1M-file index.
- [ ] Trashing from Space/Find/Cleanup updates every room consistently. (Logic in AppModel.apply reviewed; not clicked through in the UI.)

## Risk Assessment
- Non-ASCII case folding only exact-match in fast path → fall back to `localizedCaseInsensitiveContains` when
  the query is non-ASCII.
