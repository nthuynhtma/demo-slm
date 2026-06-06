# CLAUDE.md — Offline Chat Flutter (LiteRT-LM + Gemma 4 E2B)

## Project Overview

Build a fully offline AI chatbot in Flutter (Android + iOS) using:
- **Inference engine**: LiteRT-LM via platform channels
- **Model**: Gemma 4 E2B Instruct in `.litertlm` format for mobile
- **RAG**: Fully offline retrieval with local embeddings and vector search
- **Goal**: Prototype and feasibility demo with a clean migration path to a more disciplined runtime workflow

## Architecture Source of Truth

This document defines the **target architecture** for the application workflow.
If the current implementation differs, follow this document and the rules under `.claude/rules/`.

### Canonical Workflow

#### App Start

```text
App Start
-> Check Model Status + Check Indexed Documents (in parallel)
-> Model Downloaded?
-> If not downloaded: prompt download
-> If downloaded: auto preload model
-> Ready
```

#### User Typing

```text
User Typing
-> Preload model if needed
```

#### Send Message

```text
Send Message
-> EnsureModelLoaded
-> RetrieveContext (optional)
-> TokenBudgeting
-> Generate
-> Batch UI Updates
-> Finalize Message
```

#### App Background

```text
App Background
-> Release model resources if required
```

## Architecture Decisions

### 1. Model lifecycle is explicit

Download, preload, ensure-loaded, and release are separate lifecycle stages.
`EnsureModelLoaded` may load a downloaded model into memory, but it must not trigger a first-time download.

### 2. Startup is orchestrated, not incidental

The app must perform model-status and indexed-document checks as an explicit startup flow.
Startup decides whether to prompt for download or auto-preload the model before entering the ready state.

### 3. Generation uses a staged pipeline

Message send is a pipeline, not a single monolithic bloc handler:
- Ensure model loaded
- Retrieve optional context
- Apply token budgeting
- Generate
- Batch streaming updates for UI efficiency
- Finalize the assistant message

### 4. Streaming is native-first, UI-batched

Native layers may emit partial tokens at high frequency, but Dart/UI state should coalesce those events into batched updates to reduce rebuild pressure and keep message finalization deterministic.

### 5. Resource release is lifecycle-aware

The app may release LiteRT-LM resources when backgrounded, under memory pressure, or when the owning feature is disposed.
This policy must be explicit and testable.

### 6. Indexed document status must be trustworthy at startup

If startup reports indexed-document availability, that status must come from durable state.
An in-memory-only store is acceptable for experimentation, but it must be treated as a temporary limitation rather than the long-term architecture.

## High-Level Component Model

```text
Flutter UI Layer
    │
    ▼
Chat / App Workflow Coordinator (flutter_bloc)
    │
    ├── Startup Flow
    │     • checkModelStatus()
    │     • checkIndexedDocuments()
    │     • promptDownloadIfNeeded()
    │     • autoPreloadIfDownloaded()
    │
    ├── Generation Pipeline
    │     • ensureModelLoaded()
    │     • retrieveContext()
    │     • applyTokenBudget()
    │     • generate()
    │     • batchUiUpdates()
    │     • finalizeMessage()
    │
    ├── Model Lifecycle Service
    │     • isModelDownloaded()
    │     • downloadModel()
    │     • preloadModel()
    │     • ensureModelLoaded()
    │     • releaseModel()
    │
    └── RAG Services
          • indexDocuments()
          • retrieveContext()
          • reportIndexedDocumentStatus()
```

## Tech Stack

| Layer | Technology |
|-------|------------|
| UI | Flutter 3.x, flutter_bloc |
| Inference | LiteRT-LM via platform channels (0.10.36) |
| Model | `litert-community/gemma-4-E2B-it-litert-lm` (text-only .litertlm) |
| Mobile model artifact | `.litertlm` |
| Web artifact | `.task` |
| Embedding | MiniLM via `fonnx` or another local embedding runtime |
| Vector Store | `sqlite_vec` preferred, in-memory fallback only for prototyping |
| Storage | `flutter_secure_storage`, `path_provider`, durable metadata store as needed |
| Streaming | Native partials -> batched Dart/UI updates |

## Key Constraints

- **Model size**: Gemma 4 E2B is about 2.6 GB and requires resumable download plus caching.
- **Memory**: Devices need enough RAM to load and run the model; the app must release resources when appropriate.
- **No silent first-use download**: Missing models must trigger an explicit download prompt rather than being downloaded inside the send flow.
- **Offline requirement**: After the model and embeddings are present locally, inference and retrieval stay on-device.
- **Context window**: Gemma 4 E2B has an approximately 8K token window, so history, retrieved context, and response headroom must be budgeted together.
- **Platform constraints**: Android prefers NNAPI with CPU fallback; iOS uses Core ML where available.

## Project Structure

```text
lib/
├── core/
│   ├── channels/
│   └── errors/
├── features/
│   ├── chat/
│   ├── model_manager/
│   └── rag/
└── native/
    ├── android/
    └── ios/
```

The current codebase may still keep startup, lifecycle, and generation concerns inside `ChatBloc`.
That is acceptable during migration, but the behavior must move toward the workflow defined above.

## Documentation Baseline

- The mobile source-of-truth model format is `.litertlm`.
- The preferred Hugging Face repo is `litert-community/gemma-4-E2B-it-litert-lm`.
- iOS uses session-based generation for `MediaPipeTasksGenAI 0.10.36`.
- Android uses `tasks-genai:0.10.36`.
- Version 0.10.36 required để support `STABLEHLO_COMPOSITE` op trong model .litertlm.
- Startup, typing preload, generation staging, streaming batching, and background release are now first-class architecture decisions.
- Documentation may lead implementation during this migration; implementation changes should align to docs in a phased manner.

## Related Files

- `rules/model-lifecycle.md`
- `rules/startup-flow.md`
- `rules/generation-pipeline.md`
- `rules/streaming-updates.md`
- `rules/resource-management.md`
- `rules/inference.md`
- `rules/rag.md`
- `rules/flutter-patterns.md`
- `skills/model-loader.md`
- `skills/ios-litert-bridge.md`

## Implementation Status (updated 2026-06-06)

All six architectural tasks from the ADR-2026-06-05 migration plan have been implemented.

| # | Task | Status | Key files |
|---|------|--------|-----------|
| 1 | Fix TextChunker infinite loop (short text ≤ 448 chars) | ✅ Done | `rag/indexer/text_chunker.dart` |
| 2 | Durable Vector Store — persist to `rag_store.json` | ✅ Done | `rag/vector_store/vector_store.dart` |
| 3 | Canonical Startup Flow (`checkingStartup` → `needsDownload` / auto-preload) | ✅ Done | `chat/bloc/chat_bloc.dart`, `chat_state.dart`, `chat_screen.dart` |
| 4 | App Lifecycle Observer — release model on background, reload on foreground | ✅ Done | `chat/screens/chat_screen.dart`, `chat/bloc/chat_bloc.dart` |
| 5 | Streaming Update Batching — 100 ms flush timer (`_tokenBuffer`) | ✅ Done | `chat/bloc/chat_bloc.dart` |
| 6 | Token Budget Allocator — 8 K context window management | ✅ Done | `chat/bloc/token_budget_allocator.dart` |
| 7 | Test suite — fix hanging `IndexDocument` test via `NullVectorStorePersistence` | ✅ Done | `test/rag_chat_test.dart`, `vector_store.dart` |

### Architecture notes
- `VectorStore` now accepts an optional `VectorStorePersistence` backend.
  - Production default: `DiskVectorStorePersistence` (path_provider → ApplicationSupport).
  - Unit tests inject `NullVectorStorePersistence` to avoid Flutter-binding requirement.
- `ChatBloc` constructor dispatches `StartupRequested`; tests must call
  `TestWidgetsFlutterBinding.ensureInitialized()` at the top of `main()`.

