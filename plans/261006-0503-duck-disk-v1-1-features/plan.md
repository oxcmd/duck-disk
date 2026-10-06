---
title: "Duck Disk 1.1 — AI models, treemap, saved search index, Clear Cache"
description: "Four features DiskBuddy 3.0 has that Duck Disk 1.0 lacks"
status: completed
priority: P1
effort: "1-2d"
tags: [macos, swiftui, features]
created: 2026-10-06
---

# Duck Disk 1.1

## Overview

Gap analysis against the DiskBuddy 3.0 announcement (2026-10-05) and a screenshot of its treemap.
User chose all four gaps on 2026-10-06. Same constraints as 1.0: SwiftPM + Command Line Tools, Apple silicon only,
every removal through `TrashService` + `SafetyGuard`, English UI, `DuckDiskChecks` as the test runner.

## Phases

| # | Phase | Status |
|---|-------|--------|
| 1 | [AI models category](./phase-01-ai-models.md) | Completed |
| 2 | [Treemap in Space](./phase-02-treemap.md) | Completed |
| 3 | [Saved search index](./phase-03-search-index.md) | Completed |
| 4 | [Clear Cache in Applications](./phase-04-clear-cache.md) | Completed |

Phases are independent; 1 and 4 touch core + one room each, 2 and 3 touch Space/Find and core helpers.

The screenshot showed DiskBuddy's "tree view" is a treemap, so phase 2 builds a treemap. Index compression is LZ4:
LZFSE took 6.8 s to save 2.56M files; LZ4 takes 0.5 s (load 0.4 s, 51 MB).

## Non-goals

Per-model removal inside Ollama's shared blob store (whole Ollama folder is one item), logical/compressed size
(DiskBuddy shows it; the scanner only reads allocated size), "Add to Cleanup" from the inspector.

## Acceptance Criteria

- [x] Overview/Cleanup show an "AI models" category (Worth a look, unselected) listing Ollama, LM Studio,
      Hugging Face, GPT4All, Jan, Draw Things, DiffusionBee, MacWhisper, whisper, PyTorch hub and stray
      .gguf/.ggml/.safetensors/.ckpt files ≥ 100 MB; nothing double-counted with Developer files.
- [x] Space has a Treemap mode: nested rectangles with name/size headers, coloured by category, Size/Files/Age
      tabs, depth −/+, click selects (inspector), double-click zooms, breadcrumb, hover status line.
- [x] After a scan the index is saved; on the next launch Find works before any scan, labelled with the index date;
      missing files are hidden; a setting turns it off and removes saved indexes.
- [x] Applications detail has "Clear Cache" (caches, web storage, container caches), app must quit first.
- [x] Checks cover AI model classification, treemap layout, index round trip and cache paths; all pass.

## Open Questions

None.

<!-- slug: duck-disk-v1-1-features -->
