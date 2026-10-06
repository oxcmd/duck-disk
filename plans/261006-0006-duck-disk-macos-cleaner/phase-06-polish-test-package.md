---
phase: 6
title: "Polish, test, package"
status: completed
priority: P1
effort: "0.5d"
dependencies: [3, 4, 5]
---

# Phase 6: Polish, test, package

## Overview
Checks runner, perf validation, review, packaging and docs.

## Requirements
- `DuckDiskChecks`: fixture tree tests for scanner, classifier, safety guard, duplicate finder, search, snapshot
  diff, formatter.
- Perf: time a home scan in release build; record result.
- Code review pass on core + trash paths.
- Package: `build/Duck Disk.app` + optional `build/DuckDisk.dmg` (hdiutil).
- Docs: `docs/README.md` (build, run, FDA, safety model).

## Success Criteria
- [x] Checks pass, app launches from build output, review findings resolved.
