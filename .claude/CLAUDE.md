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
| Inference | LiteRT-LM via platform channels (0.10.36) |
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
- iOS uses session-based generation for `MediaPipeTasksGenAI 0.10.36`.
- Android uses `tasks-genai:0.10.36`.
- Version 0.10.36 required để support `STABLEHLO_COMPOSITE` op trong model .litertlm.
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
| 8 | Background Downloader Migration — Dio → `background_downloader` | ✅ Done | `model_downloader.dart`, `model_loader.dart`, `chat_bloc.dart`, `chat_event.dart`, `chat_state.dart`, `chat_screen.dart`, `main.dart`, `AndroidManifest.xml` |

### Architecture notes
- `VectorStore` now accepts an optional `VectorStorePersistence` backend.
  - Production default: `DiskVectorStorePersistence` (path_provider → ApplicationSupport).
  - Unit tests inject `NullVectorStorePersistence` to avoid Flutter-binding requirement.
- `ChatBloc` constructor dispatches `StartupRequested`; tests must call
  `TestWidgetsFlutterBinding.ensureInitialized()` at the top of `main()`.
- **Download engine**: `background_downloader` replaces Dio. Download updates flow: native engine → `FileDownloader().updates` stream → `ModelDownloader._handleStatusUpdate()` → `StreamController.broadcast()` → `ModelLoader.downloadUpdates` → `ChatBloc._downloadSubscription` → `DownloadUpdateReceived` event → state machine transitions.
- **Pause/Resume/Cancel**: Exposed as `ChatEvent` handlers mapped to `ModelDownloader.pauseDownload()/resumeDownload()/cancelDownload()`. UI buttons in both main screen and drawer.
- **Android permission**: `POST_NOTIFICATIONS` required in `AndroidManifest.xml` for background download notifications on Android 13+.
- **Init order**: `main()` is now `async`; `modelDownloader.initialize()` must be called before `runApp()` to configure notifications and subscribe to background updates.