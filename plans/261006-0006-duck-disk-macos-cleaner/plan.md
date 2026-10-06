---
title: "Duck Disk — native macOS disk cleaner (DiskBuddy-style)"
description: "SwiftUI macOS app with 9 rooms: Overview, Find, Space, Cleanup, Duplicates, Applications, Monitor, Compress, Activity"
status: completed
priority: P1
effort: "5-7d"
tags: [macos, swiftui, swiftpm, disk-cleaner]
created: 2026-10-06
---

# Duck Disk — native macOS disk cleaner

## Overview

Clone of diskbuddy.com behaviour as a native macOS app named **Duck Disk**. One scan maps every byte of a
volume or folder; kept space shows in grey, clearable space in colour. Nothing is deleted — every removal goes
to the Trash, after review. No account, no network, no analytics, no licensing.

Decisions (user-confirmed 2026-10-06): SwiftUI native macOS · all 9 rooms · English UI · name "Duck Disk" ·
no license/payment.

## Constraints

- Toolchain: Swift 6.2 Command Line Tools only (no Xcode). Build with SwiftPM, bundle `.app` via script,
  ad-hoc codesign. Probed OK: SwiftUI, Charts, AVFoundation, ImageIO, CryptoKit, IOKit.ps, libproc,
  `getattrlistbulk`.
- XCTest and swift-testing are NOT available → tests live in an executable target `DuckDiskChecks`
  (`swift run DuckDiskChecks`) with a tiny assert harness.
- Target macOS 14+, arm64 (host arch; universal needs Xcode build system).
- Swift 5 language mode (Swift 6 compiler) to keep concurrency friction low; UI state `@MainActor @Observable`.

## Non-goals

Licensing/activation, Windows build, auto-update, Mac App Store sandbox, emptying the Trash, privileged
helper for root-owned files (those are reported, user can reveal in Finder).

## Architecture

```
Package.swift
Sources/DuckDiskCore/   pure logic, no SwiftUI: scanner, tree, classifier, safety, trash, duplicates,
                        apps, monitor samplers, compressor, activity store, formatting
Sources/DuckDisk/       SwiftUI app: AppModel, design tokens, sidebar shell, 9 room views, inspector, settings
Sources/DuckDiskChecks/ executable test runner for DuckDiskCore
scripts/package-app.sh  release build → "dist/Duck Disk.app" (+ optional .dmg), icon, Info.plist, codesign
scripts/make-icon.swift renders the duck icon → AppIcon.icns via iconutil
```

Output goes to `dist/` (a local hook blocks paths named `build`). The scanner class is `DiskScanner`
(`Scanner` clashes with Foundation).

Data flow: `DiskScanner` (parallel getattrlistbulk walker) → immutable-ish `ScanTree` (DirNode classes + compact
FileEntry structs) → `Classifier` post-pass → `CleanupItem`s by category → `AppModel` selection → `TrashService`
(FileManager.trashItem, `SafetyGuard` first) → tree sizes patched + `ActivityStore` event.

## Phases

| # | Phase | Status |
|---|-------|--------|
| 1 | [Foundation & app shell](./phase-01-foundation-app-shell.md) | Completed |
| 2 | [Scan engine & Overview](./phase-02-scan-engine-overview.md) | Completed |
| 3 | [Space, Find, Cleanup, Inspector](./phase-03-space-find-cleanup.md) | Completed |
| 4 | [Duplicates & Applications](./phase-04-duplicates-applications.md) | Completed |
| 5 | [Monitor, Compress, Activity](./phase-05-monitor-compress-activity.md) | Completed |
| 6 | [Polish, test, package](./phase-06-polish-test-package.md) | Completed |

Dependencies: 1 → 2 → 3 → 4; 5 needs 1 (+ scan tree for Compress suggestions / Activity snapshots); 6 last.

## Acceptance Criteria

- [x] `scripts/package-app.sh` produces a launchable, ad-hoc signed `dist/Duck Disk.app` with duck icon.
- [x] All 9 rooms reachable from sidebar, English copy. Dark rendering verified; light mode not visually checked.
- [x] Home-folder scan of 2.56M files: 11.8 s warm cache (109 s first, cold cache); progress shown live.
- [x] Overview donut: kept = grey, clearable = colour; "X ready to clear"; Move to Trash with confirmation.
- [x] Nothing ever hard-deleted: every removal uses Trash; protected paths can never be staged.
- [x] Duplicates matched by size → partial hash → full SHA-256; hardlinks/clones not counted as waste.
- [x] Applications: app + leftovers + background items, uninstall to Trash (uninstall not clicked through in the UI).
- [x] Monitor: live CPU, memory, listening ports, battery.
- [x] Compress: video (AVFoundation HEVC/H.264) and photo (HEIC) shrink; originals to Trash only when result smaller.
- [x] Activity: weekly reclaimed-space chart + snapshot compare.
- [x] `DuckDiskChecks` passes (100 checks, debug build).

## Open Questions

None.

<!-- slug: duck-disk-macos-cleaner -->
