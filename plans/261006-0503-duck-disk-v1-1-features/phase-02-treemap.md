---
phase: 2
title: "Treemap in Space"
status: completed
priority: P1
effort: "4h"
dependencies: []
---

# Phase 2: Treemap in Space

## Overview
A third Space mode, modelled on DiskBuddy's treemap screenshot: nested squarified rectangles drawn in a Canvas.

## Requirements
- Core `Treemap.squarify(values:in:)` (pure, tested) returning rects whose areas are proportional and inside bounds.
- Layout per folder: header strip (name + size) when the rect is big enough, children inside; at most 150 children,
  the rest merged into one "N smaller items" rect; stop at the depth limit or below ~6 pt.
- Tabs: Size (area = bytes), Files (area = file count), Age (area = bytes, colour = last modified, recent = bright).
- Colour: cleanup category colour when the node is or is inside a cleanup item; otherwise kept tones
  (media, apps, system, other). Depth control 1…8 (default 4).
- Click selects (inspector), double-click on a folder zooms in (breadcrumb shared with Folders mode),
  hover shows path, size, files and age in a status line. Right-click menu like other rooms.
- Inspector gains "Of parent" and "Largest inside" (top 3 children).

## Related Code Files
- Create: `Sources/DuckDiskCore/Treemap.swift`, `Sources/DuckDisk/Components/TreemapView.swift`
- Modify: `Sources/DuckDisk/Rooms/SpaceRoom.swift`, `Sources/DuckDisk/Components/InspectorView.swift`

## Success Criteria
- [x] Squarify check: areas proportional within 1%, rects inside bounds, no overlap.
- [x] Treemap renders the fixture with headers and colours (debug snapshot).
