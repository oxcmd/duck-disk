---
phase: 1
title: "AI models category"
status: completed
priority: P1
effort: "3h"
dependencies: []
---

# Phase 1: AI models category

## Overview
New cleanup category `aiModels` ("AI models", Worth a look) for locally downloaded model weights.

## Requirements
- Known locations (home-relative), item granularity:
  - `.ollama/models` → one item (blobs are shared between models); detail lists model names from manifests.
  - `.lmstudio/models/*/*`, `.cache/lm-studio/models/*/*` → one item per model folder.
  - `.cache/huggingface/hub/models--*` and `datasets--*` → one item each, named `org/name`.
  - `Library/Application Support/nomic.ai/GPT4All/*` model files; `jan/models/*`,
    `Library/Application Support/Jan/data/models/*/*`; `Library/Containers/com.liuliu.draw-things/Data/Documents/Models/*`;
    `.diffusionbee/downloads/*`; `Library/Application Support/MacWhisper/models/*`; `.cache/whisper/*`;
    `.cache/torch/hub/checkpoints/*`; `Library/Application Support/Msty/models`.
  - Stray files anywhere under home with extension gguf, ggml, safetensors, ckpt ≥ `aiStrayMinSize` (100 MB).
- Developer rule for `~/.cache/*` skips `huggingface`, `lm-studio`, `whisper`, `torch` so models land in AI models.
- Category listed after Developer files (no path is shared with it); colour green, SF symbol `brain`.

## Related Code Files
- Modify: `Sources/DuckDiskCore/{CleanupCategory,Classifier}.swift`, `Sources/DuckDisk/Theme.swift`,
  `Sources/DuckDiskChecks/{Fixture,main}.swift`

## Success Criteria
- [x] Fixture with Ollama, LM Studio, Hugging Face and a stray .gguf → each appears once under AI models.
