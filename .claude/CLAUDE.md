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
-> Check Model Status + Check Indexed Documents + Check Background Download (in parallel)
-> Model Downloaded?
-> If not downloaded: prompt download
-> If downloaded: auto preload model
-> If download active/paused: show download progress UI
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
Startup also checks for active background download tasks (e.g. if app was restarted mid-download).

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

### 7. Download resilience via background_downloader

Model downloads (2.6 GB) use `background_downloader` (not Dio) to survive app suspend/terminate.
The download engine uses native iOS `URLSessionDownloadTask` and Android `DownloadManager`.
Pause, resume, and cancel are first-class actions exposed through the UI.
Android requires `POST_NOTIFICATIONS` permission for download progress notifications (Android 13+).
`main()` must be `async` to call `modelDownloader.initialize()` before `runApp()`.

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
    │     • checkBackgroundDownloadTask()
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
    │     • pauseDownload()
    │     • resumeDownload()
    │     • cancelDownload()
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
| Inference | LiteRT-LM via platform channels (0.10.35) |
| Model | `litert-community/gemma-4-E2B-it-litert-lm` (text-only .litertlm) |
| Mobile model artifact | `.litertlm` |
| Web artifact | `.task` |
| Embedding | MiniLM via `fonnx` or another local embedding runtime |
| Vector Store | `sqlite_vec` preferred, in-memory fallback only for prototyping |
| Download Engine | `background_downloader` (native Android/iOS, survives suspend/terminate) |
| Storage | `flutter_secure_storage`, `path_provider`, durable metadata store as needed |
| Streaming | Native partials -> batched Dart/UI updates |

## Key Constraints

- **Model size**: Gemma 4 E2B is about 2.6 GB and requires resumable background download plus caching.
- **Memory**: Devices need enough RAM to load and run the model; the app must release resources when appropriate.
- **No silent first-use download**: Missing models must trigger an explicit download prompt rather than being downloaded inside the send flow.
- **Download resilience**: Downloads survive app suspend/terminate via `background_downloader` native engine. Pause/Resume/Cancel controls are exposed in UI.
- **Offline requirement**: After the model and embeddings are present locally, inference and retrieval stay on-device.
- **Context window**: Gemma 4 E2B has an approximately 8K token window, so history, retrieved context, and response headroom must be budgeted together.
- **Platform constraints**: Android prefers NNAPI with CPU fallback; iOS uses Core ML where available.
- **Android notifications**: `POST_NOTIFICATIONS` permission required for download progress notifications (Android 13+).

## Project Structure

```text
lib/
├── core/
│   ├── channels/
│   └── errors/
├── features/
│   ├── chat/
│   │   ├── bloc/
│   │   │   ├── chat_bloc.dart       — download subscription, state machine
│   │   │   ├── chat_event.dart      — pause/resume/cancel download events
│   │   │   ├── chat_state.dart      — isDownloadPaused field
│   │   │   └── token_budget_allocator.dart
│   │   ├── models/
│   │   └── screens/
│   │       └── chat_screen.dart     — pause/resume/cancel UI buttons
│   ├── model_manager/
│   │   └── download/
│   │       └── model_downloader.dart  — background_downloader integration
│   │   └── loader/
│   │       └── model_loader.dart      — downloadUpdates stream proxy
│   └── rag/
│       ├── indexer/
│       ├── models/
│       ├── retriever/
│       └── vector_store/
└── native/
    ├── android/
    └── ios/
```

The current codebase may still keep startup, lifecycle, and generation concerns inside `ChatBloc`.
That is acceptable during migration, but the behavior must move toward the workflow defined above.

## Documentation Baseline

- The mobile source-of-truth model format is `.litertlm`.
- The preferred Hugging Face repo is `litert-community/gemma-4-E2B-it-litert-lm`.
- iOS uses session-based generation for `MediaPipeTasksGenAI 0.10.35`.
- Android uses `tasks-genai:0.10.35`.
- Startup, typing preload, generation staging, streaming batching, and background release are now first-class architecture decisions.
- **Download engine**: `background_downloader` thay thế `Dio` cho model 2.6 GB. Download sống sót qua app suspend/terminate nhờ native engine. Updates reactive qua Stream pattern.
- **Download status machine**: `ModelDownloadStatus { none, enqueued, downloading, paused, complete, failed, canceled }`.
- **Download → Preload**: Khi download hoàn tất, `ChatBloc` tự động dispatch `PreloadModel`.
- **Startup download check**: Startup flow kiểm tra `getActiveDownloadUpdate()` để khôi phục trạng thái download background.
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
---

## Implementation Status

**Latest Update**: 2026-06-06 — All 8 architectural tasks completed ✅

For detailed implementation tracking with decisions, rationale, and phase notes:
- **Refer to**: `/memories/repo/` files (decision history, implementation sync notes, gotchas)
- **Refer to**: `rules/` files (platform setup, patterns, constraints)
- **Refer to**: `lib/` source code (current implementation)

Key milestones:
- ✅ Model lifecycle (download → preload → release)
- ✅ Startup flow (parallel checks, auto-preload)
- ✅ Generation pipeline (ensure-loaded → retrieve → budget → generate → batch → finalize)
- ✅ Streaming batching (100ms flush)
- ✅ Token budgeting (8K context window)
- ✅ Background downloader (pause/resume/cancel)
- ✅ RAG persistence (durable vector store)
- ✅ iOS platform (SPM deployment target fix)

### Key Implementation Patterns

**Model & Download**:
- `background_downloader` native engine survives app suspend/terminate
- `ModelDownloader` → `ModelLoader` → `ChatBloc` event flow
- Status machine: `none → enqueued → downloading → paused → complete | failed | canceled`
- Download complete auto-triggers `PreloadModel` event

**Streaming & UI**:
- Native tokens buffered in Dart (100ms flush timer)
- Batched commits to `ChatState` (reduces rebuilds)
- Finalization flushes remainder before terminal state

**Testing**:
- `VectorStore` pluggable persistence (`DiskVectorStorePersistence` vs `NullVectorStorePersistence`)
- `ChatBloc` auto-dispatches `StartupRequested` in constructor
- Tests must call `TestWidgetsFlutterBinding.ensureInitialized()`

**Platform**:
- Android: `POST_NOTIFICATIONS` permission required (Android 13+)
- iOS: SPM deployment target `16.0+` (enforced via Podfile post_install hook)
- `main()` async: `modelDownloader.initialize()` before `runApp()`