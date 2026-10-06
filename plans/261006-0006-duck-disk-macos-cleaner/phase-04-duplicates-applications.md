---
phase: 4
title: "Duplicates & Applications"
status: completed
priority: P1
effort: "1d"
dependencies: [2]
---

# Phase 4: Duplicates & Applications

## Overview
Content-matched duplicate finder and per-app footprint/uninstaller.

## Requirements
- Duplicates: candidates from scan tree (size ≥ min size setting, default 1 MB; skip bundles, ~/Library,
  .git, node_modules, photoslibrary); group by size → hash first+last 64 KB → full SHA-256 (CryptoKit, streamed);
  dedupe by fileid; skip pairs sharing APFS clone id. Keep suggestion: oldest file outside Downloads.
  UI: groups by wasted bytes, radio keep per group, auto-select, Move duplicates to Trash. Feeds the Duplicates
  category in Overview/Cleanup.
- Applications: scan `/Applications`, `~/Applications` (recursive one level for folders like Utilities);
  name, icon, version, bundle id, bundle size, last used (Spotlight `kMDItemLastUsedDate`), leftovers
  (Application Support, Caches, Containers, Group Containers by team id, Preferences, Saved Application State,
  HTTPStorages, WebKit, Logs, LaunchAgents plists referencing the bundle id), background items (launch
  agents/daemons, running processes from that bundle). Sort by footprint. Uninstall = quit check + app + leftovers
  to Trash (confirmation lists everything). Apple apps in /System/Applications are excluded.

## Related Code Files
- Create: `Sources/DuckDiskCore/{DuplicateFinder,AppInventory}.swift`,
  `Sources/DuckDisk/Rooms/{DuplicatesRoom,ApplicationsRoom}.swift`

## Success Criteria
- [x] Fixture with identical/different-same-size/hardlinked files → only identical grouped.
- [ ] Uninstalling a test app moves app + leftovers to Trash. (Not clicked through in the UI; trash path, safety guard and single-owner data assignment are covered by checks.)

## Risk Assessment
- Root-owned apps fail trashItem → report "needs administrator" and offer Reveal in Finder.
