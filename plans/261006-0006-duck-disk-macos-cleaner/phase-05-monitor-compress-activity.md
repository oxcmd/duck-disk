---
phase: 5
title: "Monitor, Compress, Activity"
status: completed
priority: P2
effort: "1.5d"
dependencies: [1, 2]
---

# Phase 5: Monitor, Compress, Activity

## Overview
Live system monitor, media compressor, reclaimed-space history with snapshots.

## Requirements
- Monitor (1 s timer while visible): CPU total + per core (host_processor_info deltas), memory (host_statistics64:
  app, wired, compressed, cached, swap via `vm.swapusage`, pressure), top processes by CPU & memory (libproc,
  mach timebase conversion), listening TCP/UDP ports (proc_pidfdinfo socket info → port, pid, process; Quit
  action with confirm), battery (IOPowerSources + AppleSmartBattery: %, charging, time left, cycles, health).
  60-sample line charts.
- Compress: add files (drag-drop, picker, or "Large videos/photos" suggestions from scan); presets — Video:
  High (HEVC original size), Balanced (HEVC 1080p), Small (H.264 720p); Photo: HEIC quality 0.8/0.6/0.45 with
  optional max 4K edge, metadata + orientation kept. Output beside original; if smaller and "Replace originals"
  on → original to Trash and compressed takes its place; otherwise discard result. Per-file progress + savings.
- Activity: `~/Library/Application Support/Duck Disk/activity.json` (cleanup events) and `snapshots/*.json`
  (date, target, capacity, used, category totals, folder sizes ≥ 50 MB to depth 4). Weekly bar chart of reclaimed
  bytes (12 weeks), totals, event list; snapshot compare (pick two → biggest grew/shrank folders).

## Related Code Files
- Create: `Sources/DuckDiskCore/{SystemMonitor,PortScanner,Battery,MediaCompressor,ActivityStore,Snapshot}.swift`,
  `Sources/DuckDisk/Rooms/{MonitorRoom,CompressRoom,ActivityRoom}.swift`

## Success Criteria
- [x] Monitor numbers match Activity Monitor ballpark; ports list shows a known listener.
- [x] Compressing a sample video/photo yields smaller file and valid playback/preview.

## Risk Assessment
- Other users' processes unreadable without root → listed as unavailable, not errors.
