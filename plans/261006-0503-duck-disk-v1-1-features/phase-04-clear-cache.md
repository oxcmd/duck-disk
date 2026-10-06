---
phase: 4
title: "Clear Cache in Applications"
status: completed
priority: P2
effort: "1h"
dependencies: []
---

# Phase 4: Clear Cache in Applications

## Overview
One action that clears an app's caches but keeps its settings and documents.

## Requirements
- `AppInfo.caches`: owned data of kind Caches, Web storage, Web data, plus `<container>/Data/Library/Caches`
  for owned containers.
- "Clear Cache (size)" button in the app detail; disabled when empty; if the app runs, ask to quit first;
  goes through the normal Trash confirmation; the list refreshes afterwards.

## Related Code Files
- Modify: `Sources/DuckDiskCore/AppInventory.swift`, `Sources/DuckDisk/Rooms/ApplicationsRoom.swift`

## Success Criteria
- [x] Check: cache paths include Caches/web data and container caches, never Preferences or Application Support.
