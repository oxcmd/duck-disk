---
phase: 2
title: "Scan engine & Overview"
status: completed
priority: P1
effort: "1.5d"
dependencies: [1]
---

# Phase 2: Scan engine & Overview

## Overview
Fast parallel scanner, size tree, category classifier, safety guard, trash service and the Overview room.

## Requirements
- Scanner: `getattrlistbulk` (FSOPT_PACK_INV_ATTRS = 0x8) per directory, N worker threads over a shared queue;
  attrs: name, objtype, modtime, acctime, flags, fileid, dir mountstatus, file linkcount, file allocsize.
  Count allocated size; dedupe hardlinks by fileid when linkcount > 1; skip `/System/Volumes`, `/Volumes`,
  `/dev`, other mount points when scanning `/`; record unreadable dirs (EPERM/EACCES) count.
- Progress: files, bytes, current dir, elapsed — published ~10×/s; cancellable.
- Tree: `DirNode` (final class: name, parent, subdirs, files [FileEntry], totalSize, fileCount, mediaBytes),
  `FileEntry` struct (name, size, mtime, atime, isMedia flag). Path rebuilt on demand.
- Volume info: total, available (important usage), name. "System & other" = used − scanned.
- Classifier (post-scan, path rules relative to scan root + home):
  - Safe: Caches (`~/Library/Caches/*`, container caches, `/Library/Caches/*` if writable),
    Logs & temp (`~/Library/Logs/*`, DiagnosticReports, `/Library/Logs/*` writable, old `$TMPDIR` items),
    App leftovers (reverse-DNS items in Application Support / Containers / Preferences / Saved Application State /
    HTTPStorages / WebKit / Caches whose bundle id matches no installed app; never `com.apple.*`).
  - Worth a look (unchecked by default): Developer files (Xcode DerivedData/Archives/DeviceSupport, CoreSimulator
    caches, npm/yarn/pip/gradle/cargo/go caches, stale `node_modules`), Old downloads (Downloads items older than
    N days or installers .dmg/.pkg/.xip), Duplicates (filled in phase 4).
  - Kept: Photos & media, Apps, System & other, Documents & other.
- SafetyGuard: deny list (/System, /usr, /bin, /sbin, /private/var/db, ~/Library/Keychains, Mobile Documents,
  *.photoslibrary, Mail, Messages, com.apple.bird/CloudKit caches…) + must be inside home or writable.
- TrashService: `FileManager.trashItem`, per-item result, concurrent off-main, aggregates freed bytes.
- Overview UI: donut (custom Canvas arcs with gaps, grey kept + coloured clearable), centre "X ready to clear",
  grouped list with checkboxes, footer "Found X you could clear" + "Move X to Trash", confirm sheet, done state.
- Empty state: big Scan button + FDA hint.

## Related Code Files
- Create: `Sources/DuckDiskCore/{DiskScanner,ScanTree,VolumeInfo,Classifier,CleanupCategory,SafetyGuard,TrashService,InstalledApps}.swift`,
  `Sources/DuckDisk/Rooms/OverviewRoom.swift`, `Sources/DuckDisk/Components/DonutChart.swift`

## Success Criteria
- [x] Scan of home finishes, totals match `du -sk` within a few %.
- [x] Overview shows categories, selection drives centre total; TrashService moves a real file to the Trash and refuses /System (verified with --trash-test).

## Risk Assessment
- Attribute buffer parsing mistakes → validate on fixture tree in checks (sizes, hidden files, hardlink).
- TCC prompts for Desktop/Documents/Downloads without FDA → show FDA banner; scanner tolerates EPERM.
