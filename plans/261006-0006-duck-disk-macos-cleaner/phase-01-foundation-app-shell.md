---
phase: 1
title: "Foundation & app shell"
status: completed
priority: P1
effort: "0.5d"
dependencies: []
---

# Phase 1: Foundation & app shell

## Overview
SwiftPM package, design system, sidebar shell with 9 rooms, settings window, .app bundling + icon.

## Requirements
- Functional: window with sidebar (Overview, Find, Space, Cleanup, Duplicates, Applications, Monitor, Compress,
  Activity), volume/folder picker in toolbar, Settings scene (appearance System/Light/Dark, old-download age,
  duplicate min size, excluded folders, Full Disk Access status + open-settings button).
- Non-functional: dark look like DiskBuddy (near-black bg, soft cards, rounded numerals), adaptive light mode.

## Architecture
- Design tokens `Theme`: background, panel, hairline, textPrimary/secondary; category colours
  caches #E8A33D, logs #E5534B, leftovers #D65A9C, developer #7C5CFF, downloads #4C7DFF, duplicates #3CB4C4,
  kept greys. Fonts: `.system(design: .rounded)` for figures.
- `AppModel` (@MainActor @Observable): selected room, scan target, scan state, tree, cleanup selection, inspector item.
- Info.plist: bundle id `app.duckdisk.DuckDisk`, LSMinimumSystemVersion 14.0, usage strings for
  Desktop/Documents/Downloads/removable/network volumes.

## Related Code Files
- Create: `Package.swift`, `Sources/DuckDisk/{DuckDiskApp,ContentView,Theme,AppModel,SettingsView}.swift`,
  `Sources/DuckDiskCore/Formatting.swift`, `Sources/DuckDiskChecks/main.swift`,
  `scripts/build-app.sh`, `scripts/make-icon.swift`, `Resources/Info.plist`

## Implementation Steps
1. Package with 3 targets, Swift 5 mode, macOS 14.
2. Theme + reusable components (Card, SectionHeader, SizeLabel, CategoryDot, PrimaryButton).
3. Sidebar shell + placeholder rooms; toolbar target picker (mounted volumes + Choose Folder…).
4. Settings scene with @AppStorage keys.
5. Icon renderer (CoreGraphics duck on gradient ring) → iconset → icns.
6. package-app.sh: `swift build -c release`, assemble bundle, copy icon/plist, `codesign -s - --force`.

## Success Criteria
- [x] `scripts/package-app.sh` → app launches and every room renders (verified with -snapshotDir renders). Settings window not opened by hand.

## Risk Assessment
- Ad-hoc signature changes every build → Full Disk Access must be re-granted after rebuild. Document it.
