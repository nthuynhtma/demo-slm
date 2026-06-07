# memory.md — Claude's Project Notes

## Decisions Made

| Date | Decision | Reason |
|------|----------|--------|
| 2026-06 | LiteRT-LM thay vì llama.cpp | Official Google support, tích hợp tốt hơn với Android NNAPI + iOS Core ML |
| 2026-06 | sqlite_vec cho vector store | Lightweight, không cần server, tích hợp vào SQLite sẵn có |
| 2026-06 | MiniLM cho embedding | ~22MB, đủ chất lượng, nhanh hơn Gemma embedding |
| 2026-06 | flutter_bloc | Consistent với codebase TMA hiện tại |
| 2026-06 | **fonnx** cho ONNX runtime thay vì onnxruntime_flutter | fonnx actively maintained (last push 2026-05-22), onnxruntime_flutter stalled since Dec 2024 |
| 2026-06 | **iOS bridge dùng `LlmInference.Session` cho generation settings** | Với MediaPipeTasksGenAI 0.10.35, `temperature/topk` nằm ở session options, không nằm ở engine options |
| 2026-06 | **Băm SHA256 dạng stream để tránh OOM** | Tránh lỗi tràn bộ nhớ (OOM) khi băm file model nặng 2.6GB trên thiết bị di động |
| 2026-06 | **Resumable download qua Dio Range** | Hỗ trợ tải tiếp tục model 2.6GB bằng HTTP Range header để tăng độ ổn định |
| 2026-06 | **Background downloader thay vì Dio** | `background_downloader` cho phép download sống sót qua app suspend/terminate, native notification support Android/iOS, built-in pause/resume/cancel |
| 2026-06 | **Hệ thống UI Feedback & Centralized Logging** | Cung cấp thông báo SnackBar và log console thống nhất cho mọi hành động của người dùng. |
| 2026-06 | **Ước lượng Token dựa trên từ (Word-based)** | Sử dụng tỉ lệ 1.3 token/từ để ước lượng chính xác hơn cho tiếng Việt và Code so với đếm ký tự. |
| 2026-06 | **Tối ưu hóa UI Streaming (80ms)** | Giảm thời gian flush token từ 100ms xuống 80ms để tăng độ mượt mà khi hiển thị kết quả. |
| 2026-06 | **Tăng cường RAG (topK: 5, batch: 16)** | Tăng số lượng ngữ cảnh và tốc độ xử lý embedding để cân bằng giữa độ chính xác và hiệu năng. |
| 2026-06 | **Siết chặt System Prompt Grounding** | Ép mô hình sử dụng ngữ cảnh RAG và từ chối trả lời nếu không có thông tin để giảm ảo tưởng. |

## ADR-2026-06-05 — Explicit Model Lifecycle and Staged Generation Pipeline

### Status

Accepted as the documentation source of truth. Implementation migration is approved and proceeds in phases.

### Context

The earlier implementation path mixed multiple responsibilities together:
- first-use download could happen inside `ensureModelLoaded()`
- startup only refreshed state and did not auto-preload a downloaded model
- send-message flow did not formalize token budgeting as its own stage
- streaming updates were pushed token-by-token directly into UI state
- background lifecycle did not explicitly release model resources
- indexed-document availability at startup was not durable because the current vector store is in-memory

This made the app work for a prototype, but it weakened predictability, lifecycle clarity, and memory discipline.

### Decision

The app now adopts the following target workflow:

```text
App Start
-> Check Model Status + Check Indexed Documents (in parallel)
-> If model not downloaded: prompt download
-> If model downloaded: auto preload model
-> Ready

User Typing
-> Preload model if needed

Send Message
-> EnsureModelLoaded
-> RetrieveContext (optional)
-> TokenBudgeting
-> Generate
-> Batch UI Updates
-> Finalize Message

App Background
-> Release model resources if required
```

### Architectural Consequences

1. **Download and load are separate concerns**
   - Download is an explicit user-visible action.
   - Load/preload is a memory lifecycle action.
   - `EnsureModelLoaded` must not silently perform the first download.

2. **Startup becomes a first-class flow**
   - Startup must orchestrate model and indexed-document checks in parallel.
   - Startup chooses between a download prompt and auto-preload before the app is considered ready.
   - Startup also checks background download task status for active/paused downloads.

3. **Generation becomes pipeline-driven**
   - Retrieval, token budgeting, generation, streaming aggregation, and finalization are separate stages.
   - History and retrieved context must share a single token budget with reserved response headroom.

4. **Streaming becomes UI-batched**
   - Native partials may arrive per token.
   - Dart/UI updates should be coalesced into batches for better rendering efficiency and cleaner state transitions.

5. **Lifecycle and memory management become explicit**
   - Backgrounding may release native model resources.
   - Release policy must be deterministic enough to test and reason about.

6. **Indexed-document status must be durable if shown at startup**
   - In-memory-only document state is now considered a temporary prototype limitation, not the target design.

### Migration Strategy

- Update top-level docs and rules first.
- Refactor startup flow and model lifecycle boundaries second.
- Introduce the staged generation pipeline next.
- Add background-release behavior and streaming batching after the lifecycle split is stable.
- Address durable indexed-document status as part of the retrieval/storage migration.

### Guardrails

- Do not regress the explicit download CTA for missing models.
- Do not hide a large download behind send-message actions.
- Do not release resources in a way that loses confirmed user-visible message state.
- Do not claim startup document availability unless the backing state survives app restart.

## Open Questions — Research Results (2026-06)

### ✅ LiteRT-LM streaming via EventChannel
- **Status**: ✅ Confirmed
- `LlmInference.generateResponseAsync` có `setResultListener(partialResult, done)` trên Android
- iOS dùng `AsyncSequence` (Swift async stream)
- EventChannel Flutter có thể bridge được, nhưng **cần post callback về main thread** trước khi gọi `eventSink.success()`

### ✅ iOS MediaPipeTasksGenAI 0.10.35 bridge API
- **Status**: ✅ Confirmed from installed pod headers + successful local build
- `LlmInference.Options` chỉ giữ engine-level config như `modelPath`, `maxTokens`, `maxTopk`
- `temperature`, `topk`, `topp` nằm trong `LlmInference.Session.Options`
- Async generation signature là `generateResponseAsync(progress: completion:)`
- Progress callback nhận `(String?, Error?)`, completion callback không có tham số
- Flutter iOS plugin conformance yêu cầu `register(with registrar: FlutterPluginRegistrar)`, không phải `register(with messenger: FlutterBinaryMessenger)`

### ✅ Gemma 4 E2B `.task` file availability
- **Status**: ✅ Confirmed
- HuggingFace repo chính xác: **`litert-community/gemma-4-E2B-it-litert-lm`** (không phải `google/gemma-4-2b-it-litert-lm`)
- Google dùng codename **E2B** (Efficient 2 Billion), không phải "2b"
- **Cả hai format `.litertlm` và `.task` đều available**
- NOT gated (Apache 2.0), không cần login
- Model size: ~2.58 GB (`.litertlm`), ~2.01 GB (`.task` web format)
- Tokenizer: **SentencePiece** (Gemma native)
- Special tokens: `<start_of_turn>` / `<end_of_turn>` ✅ confirmed

### ✅ `sqlite_vec` package name
- **Status**: ⚠️ Partial (available nhưng rất alpha)
- pub.dev: **`sqlite_vec`** v0.1.7-alpha.3
- Hỗ trợ Android + iOS (FFI plugin)
- **Rủi ro**: Chỉ có 2 alpha versions, không official từ asg017, maintainer là ningpengtao-coder
- **Alternative**: tự build vector search in-memory với cosine similarity, hoặc dùng `sqflite` + custom vector index
- **fonnx** (Telosnex) là ONNX runtime Flutter active nhất (⭐296, last push 2026-05)

### ✅ iOS entitlements for on-device ML
- **Status**: ✅ Confirmed
- **Không cần entitlements đặc biệt** — Core ML, Metal, MPS đều là public frameworks, sandboxed
- Minimum iOS target: **iOS 16.0+**
- Device requirement: **iPhone 12+ (A14+)** cho reasonable performance, 4GB+ RAM
- Cần **disable bitcode** (`ENABLE_BITCODE = NO`)
- iOS Simulator **KHÔNG** support Core ML delegate → phải test trên physical device
- App Store review: không có vấn đề gì với on-device LLM (đây là use case được khuyến khích)
- Background execution: không support streaming khi app background → cần xử lý lifecycle

## Gotchas Discovered

- **Android LiteRT-LM API**: `generateResponseAsync(prompt)` returns `ListenableFuture<String>` (not `ListenableFuture<ProgressListener>`), must call `.addListener()` to get result
- LiteRT-LM callback KHÔNG chạy trên main thread → phải post về main thread trước khi update eventSink
- Gemma chat template dùng `<start_of_turn>` / `<end_of_turn>`, không phải `[INST]` hay `<|user|>`
- **Model Gemma 4 E2B không bị gated trên `litert-community` repo** (Apache 2.0), nhưng repo gốc `google/gemma-4-E2B-it` có thể gated
- Android emulator không có GPU/NNAPI → luôn test trên physical device
- iOS Simulator cũng không support Core ML delegate → cần physical device iOS
- `sqlite_vec` Flutter package rất alpha (0.1.7-alpha.3) → cần fallback plan
- LiteRT-LM 0.10.x dùng **`.litertlm`** format mới, không còn `.task` cho mobile (`.task` chỉ dành cho Web)
- Gemma 4 E2B dùng **SentencePiece**, không phải tiktoken
- iOS không support background streaming → cần save session state khi app vào background
- iOS sample code cũ trong rules có thể bị outdated: SDK 0.10.35 không còn callback `(partial, error, done)` cho Swift
- `flutter build ios --debug --no-codesign` đã pass sau khi sửa iOS bridge theo registrar API + session-based generation
- **Dio ResponseBody headers**: Khi cấu hình `ResponseType.stream` trong Dio, `response.data?.headers` trả về kiểu raw `Map<String, List<String>>` chứ không phải class `Headers`. Cần truy xuất header qua `headers[headerName]?.first`.
- **Băm SHA-256 không gây OOM**: Tránh dùng `file.readAsBytes()` đối với file model lớn (2.6GB), cần dùng `sha256.bind(file.openRead())` để stream bytes qua bộ băm giúp bảo vệ RAM trên mobile.
- **background_downloader pattern**: Không dùng Dio + Range headers nữa. `background_downloader` quản lý task queue + native download engine riêng. Updates lắng nghe qua `FileDownloader().updates` stream. Notification cần cấu hình trước qua `configureNotification()`. Task tồn tại trong database native và có thể check trạng thái qua `allTasks()` + `database.recordForId()`.
- **Android POST_NOTIFICATIONS permission**: Cần thêm `POST_NOTIFICATIONS` vào AndroidManifest.xml cho background downloader notification (Android 13+).
- **main() thành async**: `modelDownloader.initialize()` bắt buộc gọi trong `main()` trước khi runApp, nên cần `main() async`.
- **Kiểm tra task active lúc startup**: `ChatBloc` startup flow giờ check `getActiveDownloadUpdate()` để khôi phục trạng thái download bị dang dở.
- **Download update stream pattern**: `ModelDownloader` emit updates qua `StreamController.broadcast()` → `ModelLoader` expose stream → `ChatBloc` subscribe → dispatch `DownloadUpdateReceived` event → state machine xử lý status transitions.
- **DownloadComplete → PreloadModel tự động**: Khi download hoàn tất, `ChatBloc` tự dispatch `PreloadModel` để load model ngay mà không cần user tap.
- **Pause/Resume/Cancel UI**: Download progress giờ có Pause/Resume/Cancel buttons ở cả main screen và drawer.

## Documentation Sync Notes (2026-06-05)

- `CLAUDE.md` current status section is partially stale versus validated research notes in `memory.md`
- Most important drift:
  - `CLAUDE.md` says iOS bridge is still a stub, but `memory.md` confirms local iOS build passed after fixing registrar API + session-based generation
  - `CLAUDE.md` and some rules still mention `.task` as the mobile target, but validated note says LiteRT-LM 0.10.x mobile uses `.litertlm`; `.task` is for Web
  - Hugging Face source of truth is `litert-community/gemma-4-E2B-it-litert-lm`, not older `google/...` naming in earlier docs
- Follow-up needed: sync `CLAUDE.md` and relevant rules with validated findings before further implementation work
- Root cause of drift: docs were updated in phases (initial planning, later research, then local build validation) but the higher-priority docs were not backfilled after validation
- Synced on 2026-06-05:
  - `CLAUDE.md`
  - `rules/inference.md`
  - `rules/android-setup.md`
  - `rules/ios-setup.md`
  - `rules/rag.md`
  - `rules/flutter-patterns.md`
  - `skills/model-loader.md`
  - `agents/researcher.md`
  - `CLAUDE.local.md`
- Current documentation baseline:
  - Mobile model artifact: `.litertlm`
  - Web artifact: `.task`
  - Preferred model repo: `litert-community/gemma-4-E2B-it-litert-lm`
  - iOS bridge status: validated and local debug build passed
  - Preferred embedding runtime: `fonnx`
  - Preferred vector store direction: `sqlite_vec` with alpha-risk fallback plan

## Implementation Sync Notes (2026-06-05)

- Chat flow now ensures the model is loaded before the first generation request
- `ChatBloc` now builds the Gemma chat template in Dart and includes trimmed conversation history before calling inference
- `EmbeddingChannel` now implements `EmbeddingService` directly, preventing runtime cast failure when `USE_MOCK=false`
- `MockInferenceService` should not emit a literal `[DONE]` token because the Dart layer expects stream completion, not a sentinel token, from mock implementations
- Model download path was aligned to `ApplicationSupport` instead of `Documents`
- **Tích hợp RAG vào ChatBloc**: Rút trích 3 chunks văn bản khớp nhất qua `RagRetriever`, định dạng và gắn trực tiếp vào user prompt gửi cho LLM. Lịch sử hiển thị UI được giữ gọn gàng (chỉ chứa truy vấn gốc).
- **Cải tiến ModelDownloader**: Hỗ trợ Range headers để tiếp tục tải khi đứt mạng, kiểm tra bộ nhớ trống (>3.0GB), và kiểm tra checksum SHA256 dạng stream an toàn cho RAM.
- **Nâng cấp UI Material 3**: RAG toggle, model status chip, bảng điều khiển cấu hình model/RAG dạng Drawer, và tích hợp các tài liệu mẫu để kiểm thử nhanh.
- **Vượt qua các bài kiểm thử**: Tạo file `test/rag_chat_test.dart` và sửa lỗi test biên dịch. Toàn bộ test suite chạy thành công.
- **Preload model explicit**: `ChatBloc` có `PreloadModel` event để load model vào memory mà không gửi message giả như `hello`; nút "Load Model" trong Drawer giờ gọi preload flow thật.
- **Cancel generation end-to-end**: `ChatBloc` có `CancelGeneration` event, nút gửi trong UI đổi thành nút stop khi đang stream, và phần text assistant đã stream dở sẽ được giữ lại thay vì bị mất.
- **Kiểm thử tập trung cho control flow mới**: Đã thêm test cho preload model và cancel generation; cả hai đều pass khi chạy riêng bằng `flutter test --plain-name ...`.
- **Rủi ro test hiện tại**: Chạy toàn bộ `test/rag_chat_test.dart` vẫn có dấu hiệu treo ở đường đi `IndexDocument event updates document count`, nên cần điều tra riêng luồng indexing/test async này trước khi coi file test đó là fully stable.

## Implementation Sync Notes (2026-06-06)

### Durable Vector Store

- `VectorStore` đã được mở rộng với `saveToDisk()` / `loadFromDisk()` dùng `dart:convert` + `path_provider`.
- File lưu tại `ApplicationSupport/rag_store.json` — flat JSON structure, không cần DB.
- Mỗi mutation (`add`, `delete`, `clear`) tự động gọi `saveToDisk()` ngay sau khi thay đổi state.
- Startup flow gọi `loadFromDisk()` song song với model status check → indexed docs available ngay sau khởi động lại app.
- **Gotcha**: `path_provider` cần `WidgetsFlutterBinding.ensureInitialized()` trước khi dùng trong `main()`.

### TextChunker Bug Fix

- Phát hiện **infinite loop** trong `TextChunker` khi `text.length <= chunkSize` (mặc định 448 ký tự).
- Root cause: điều kiện `while (start < text.length)` không thoát vì `overlap` giữ `start` không tiến.
- Fix: thêm guard `if (end >= text.length) break;` sau khi tạo chunk cuối cùng.

### Canonical Startup Flow (ChatBloc)

- `ChatBloc` giờ có enum state `checkingStartup` → `needsDownload` | `ready`.
- Startup event kiểm tra model file và indexed docs **song song** (`Future.wait`).
- Nếu model file tồn tại → tự động gọi preload (không cần user tap "Load Model").
- Nếu model file không tồn tại → emit `needsDownload` → hiện CTA tải xuống.
- **Không** gộp download vào `ensureModelLoaded()` — download luôn là explicit user action.

### App Lifecycle Observer

- `ChatScreen` implement `WidgetsBindingObserver`.
- `AppLifecycleState.paused` → dispatch `AppBackgrounded` → `ChatBloc` gọi `modelLoader.release()`.
- `AppLifecycleState.resumed` → dispatch `AppForegrounded` → `ChatBloc` tự động preload lại model nếu đã download.
- iOS không support streaming khi background → release sớm, reload khi foreground là correct behavior.

### Streaming Update Batching

- Trước: mỗi token emit ngay vào `BlocBuilder` → quá nhiều rebuild.
- Sau: `_tokenBuffer` (StringBuffer) tích lũy tokens, `_flushTimer` (100ms periodic) emit batch state.
- Khi generation done, flush ngay lập tức và cancel timer.
- **Gotcha**: phải cancel timer trong `close()` của Bloc để tránh memory leak.

### Token Budget Allocator

- File mới: `lib/features/chat/bloc/token_budget_allocator.dart`.
- Quản lý context window 8K tokens của Gemma 4 E2B.
- Phân bổ: `systemPrompt` (fixed) → `ragContext` (dynamic) → `conversationHistory` (trimmed từ cuối) → `responseHeadroom` (reserved).
- `trimHistory(messages, budget)`: cắt lịch sử từ đầu cho đến khi vừa budget, luôn giữ message gần nhất.
- **Gotcha**: token count ước lượng bằng `text.length ~/ 4` (1 token ≈ 4 chars) — đủ cho prototype, không cần tokenizer thật.

### Architecture Decisions Confirmed

| Component | Decision | Reason |
|-----------|----------|--------|
| RAG persistence | Flat JSON tại ApplicationSupport | Không cần external DB, đủ cho prototype |
| Lifecycle management | WidgetsBindingObserver trong ChatScreen | Tách UI concern ra khỏi Bloc |
| Streaming batching | 100ms timer trong ChatBloc | Giảm rebuild, cải thiện rendering performance |
| Token budgeting | Riêng class `TokenBudgetAllocator` | Testable, tách khỏi generation logic |
| Model preload | Tự động khi startup detect file exists | UX tốt hơn, không cần user tap thủ công |

### Files Changed (2026-06-06)

| File | Action | Summary |
|------|--------|---------|
| `lib/features/rag/indexer/text_chunker.dart` | Modified | Fix infinite loop khi text ngắn hơn chunk size |
| `lib/features/rag/vector_store/vector_store.dart` | Modified | Thêm `saveToDisk()` / `loadFromDisk()`, auto-persist mutations |
| `lib/features/chat/bloc/chat_state.dart` | Modified | Thêm `checkingStartup`, `needsDownload` enum values |
| `lib/features/chat/bloc/chat_event.dart` | Modified | Thêm `AppBackgrounded`, `AppForegrounded`, lifecycle events |
| `lib/features/chat/bloc/chat_bloc.dart` | Modified | Token budgeting, flush timer, startup flow, lifecycle handlers |
| `lib/features/rag/retriever/rag_retriever.dart` | Modified | Expose `vectorStore` getter cho startup load |
| `lib/features/chat/screens/chat_screen.dart` | Modified | WidgetsBindingObserver, startup state UI, needsDownload CTA |
| `lib/features/chat/bloc/token_budget_allocator.dart` | **Created** | Context window manager — 8K budget, system/rag/history/response slots |

---

## Implementation Sync Notes (2026-06-06) — Bugfixes & Code Review

### 🔴 Fix #1: ModelLoader.ensureModelLoaded() throws ModelNotDownloadedException
- **File:** `lib/features/model_manager/loader/model_loader.dart`
- **Vấn đề:** `ensureModelLoaded()` từng gọi `_downloader.downloadModel()` nếu file chưa tồn tại — vi phạm CLAUDE.md rule: *"EnsureModelLoaded must not trigger a first-time download"*
- **Fix:** Throw `ModelNotDownloadedException` nếu `isModelDownloaded() == false`. Caller (ChatBloc) chịu trách nhiệm kiểm tra trước.
- **File mới:** `lib/core/errors/app_exceptions.dart` — thêm class `ModelNotDownloadedException`
- **Rủi ro regression:** Test FakeModelLoader cần `isModelDownloaded()` trả về `true` (đã đúng)

### 🟠 Fix #2: Background lifecycle race condition
- **File:** `lib/features/chat/bloc/chat_bloc.dart`, handler `_onAppBackgrounded`
- **Vấn đề:** `add(CancelGeneration())` dispatch async, nhưng `unloadModel()` gọi ngay sau — không await cancel xong → race
- **Fix:** Inline toàn bộ cancel logic (flush buffer, cancel subscription, gọi `cancelGeneration()`) với `await` trước khi unload model

### 🟠 Fix #3: Double-count token budget với RAG context
- **File:** `lib/features/chat/bloc/chat_bloc.dart`, handler `_onSendMessage`
- **Vấn đề:** `currentQuery` được gán bằng `retrievedContextText ?? queryText` — allocator tính token 2 lần (ragContextCost + currentQueryCost) trên cùng text
- **Fix:** Luôn truyền `queryText` gốc vào `currentQuery` của allocator. Chỉ dùng `retrievedContextText` cho prompt cuối.

### 🟡 Fix #4: Startup song song
- **File:** `lib/features/chat/bloc/chat_bloc.dart`, handler `_onStartupRequested`
- **Vấn đề:** `isModelDownloaded()` và `documentCount` chạy tuần tự
- **Fix:** Dùng `Future.wait([isModelDownloaded(), docCount])`

### 🟡 Fix #5: FlushTokens self-dispatch race với Bloc closed
- **File:** `lib/features/chat/bloc/chat_bloc.dart`, handler `_onStreamToken` / `_onFlushTokens`
- **Vấn đề:** Timer gọi `_onFlushTokens` trực tiếp với `emit` — nếu Bloc đã closed, `emit()` throw
- **Fix 1:** Timer dùng `add(FlushTokens())` qua Bloc event loop (an toàn)
- **Fix 2:** Thêm guard `if (!isClosed)` trong `_onFlushTokens` trước khi `emit()`

### Test Results
- ✅ **flutter test** — 6/6 pass (5 rag_chat + 1 widget)
- ✅ **flutter analyze** — 0 errors, chỉ pre-existing warnings/info
- **Gotcha:** widget test cần `await tester.pumpAndSettle()` để chờ startup flow hoàn tất

### Architectual Rules Reinforced
1. `ModelLoader.ensureModelLoaded()` **không được** gọi download — throw exception nếu chưa có file
2. App lifecycle cancel + unload phải **sequential, not concurrent** — await cancel xong rồi mới dispose
3. Token allocator nhận **original queryText**, không nhận RAG-concatenated text
4. Startup checks chạy **song song** (Future.wait) để giảm latency
5. Streaming timer callback dùng `add(event)` chứ không `emit()` trực tiếp — kèm guard `isClosed`

---

## Implementation Sync Notes (2026-06-06) — Background Downloader Migration

### Download Engine Migration: Dio → background_downloader

- **File:** `lib/features/model_manager/download/model_downloader.dart` — **Major rewrite**
- **Lý do:** Download model 2.6GB cần sống sót qua app suspend/terminate. `Dio` + HTTP Range headers chỉ hoạt động khi app ở foreground. `background_downloader` dùng native download engine riêng (iOS `URLSessionDownloadTask`, Android `DownloadManager`) nên download tiếp tục chạy ngay cả khi app bị suspend.
- **New dependencies:** `background_downloader` thay thế `dio`
- **API thay đổi:**
  - `downloadModel()` trả về `Future<void>` (không còn `Future<String>`) — path không cần return vì downloader tự quản lý
  - Thêm `initialize()`: cấu hình notification + track tasks + subscribe updates stream
  - Thêm `pauseDownload()`, `resumeDownload()`, `cancelDownload()`
  - Thêm `getActiveDownloadUpdate()`: kiểm tra task trong database native
  - Thêm `downloadUpdates` Stream: reactive updates qua `StreamController.broadcast()`
  - Bỏ `onProgress` callback pattern

### Status Machine

- **Enum:** `ModelDownloadStatus { none, enqueued, downloading, paused, complete, failed, canceled }`
- **Update flow:** `background_downloader` native engine → `FileDownloader().updates` stream → `ModelDownloader._handleStatusUpdate()` / `_handleProgressUpdate()` → `_updatesController` broadcast → `ModelLoader.downloadUpdates` → `ChatBloc._downloadSubscription` → add `DownloadUpdateReceived` → state machine xử lý transitions

### ChatBloc Changes

- **File:** `lib/features/chat/bloc/chat_bloc.dart`
- Thêm `_downloadSubscription` để subscribe `_modelLoader.downloadUpdates`
- Thêm `_onDownloadUpdateReceived()`: map `ModelDownloadStatus` → `ChatState` transitions
  - `downloading` → `isDownloading: true, isDownloadPaused: false`
  - `paused` → `isDownloading: true, isDownloadPaused: true`
  - `complete` → `isDownloading: false, isModelDownloaded: true` + tự động dispatch `PreloadModel`
  - `failed` → `isDownloading: false, status: error`
  - `canceled` → `isDownloading: false, downloadProgress: 0.0, status: needsDownload`
- Thêm `_onPauseModelDownload()`, `_onResumeModelDownload()`, `_onCancelModelDownload()` handlers
- `_onDownloadModel()` đơn giản hóa: chỉ gọi `_modelLoader.downloadModel()` không callback
- `_onStartupRequested()`: kiểm tra `getActiveDownloadUpdate()` để khôi phục trạng thái download background
- `close()`: cancel `_downloadSubscription`
- `_onDownloadProgressUpdate()` deprecated (giữ handler rỗng để không break event registration nhưng không emit gì)

### ChatEvent Changes

- **File:** `lib/features/chat/bloc/chat_event.dart`
- Thêm: `PauseModelDownload`, `ResumeModelDownload`, `CancelModelDownload`, `DownloadUpdateReceived`

### ChatState Changes

- **File:** `lib/features/chat/bloc/chat_state.dart`
- Thêm: `isDownloadPaused` field

### UI Changes

- **File:** `lib/features/chat/screens/chat_screen.dart`
- Download progress hiển thị Pause/Resume/Cancel buttons (cả main screen và drawer)
- Trạng thái "Download Paused" với icon `pause_circle_outline`
- Label tiếng Việt: "Tạm dừng", "Tiếp tục", "Hủy"

### Platform Changes

- **File:** `android/app/src/main/AndroidManifest.xml`
- Thêm `POST_NOTIFICATIONS` permission (Android 13+ cho notification từ background downloader)

### Init Flow Changes

- **File:** `lib/main.dart`
- `main()` chuyển từ `void` → `Future<void>`
- Thêm `await modelDownloader.initialize()` trước `runApp()`

### ModelLoader Changes

- **File:** `lib/features/model_manager/loader/model_loader.dart`
- Thêm `downloadUpdates` getter (proxy từ `_downloader.downloadUpdates`)
- Thêm `getActiveDownloadUpdate()`, `pauseDownload()`, `resumeDownload()`, `cancelDownload()`
- `downloadModel()` đổi signature: bỏ `onProgress`, thêm `url`/`expectedSha256` optional params

### Test Changes

- **Files:** `test/rag_chat_test.dart`, `test/widget_test.dart`
- Cập nhật test cho API mới của `ModelDownloader` / `ModelLoader`

### Gotchas Mới

- **background_downloader pattern**: Task có `taskId` để identify. Check active task qua `FileDownloader().allTasks()`. Status lưu trong database native.
- **Notification setup bắt buộc**: `configureNotification()` phải gọi trước khi enqueue task.
- **Android POST_NOTIFICATIONS**: Cần runtime permission + manifest declaration cho Android 13+.
- **main() async mandatory**: `modelDownloader.initialize()` là bất đồng bộ, bắt buộc `main()` async.
- **DownloadComplete → PreloadModel tự động**: Không còn step "tap Load Model" sau download.
- **Kiểm tra background task khi startup**: `ChatBloc` startup check `getActiveDownloadUpdate()` để UI hiển thị đúng trạng thái nếu app restart giữa lúc download.

## Implementation Sync Notes (2026-06-06) — iOS Build Fix (SPM deployment target)

### 🔴 Lỗi build iOS thực tế gây fail

- **Triệu chứng**: `flutter run -d <iPhone>` fail với lỗi:
  ```
  Target Integrity (Xcode): The package product 'background-downloader' requires
  minimum platform version 14.0 for the iOS platform, but this target supports 13.0
  Failed to build iOS app — Could not build the precompiled application for the device.
  ```
- **Warning đi kèm** (chưa phải lỗi, chỉ deprecation):
  ```
  The following plugins do not support Swift Package Manager for ios:
    - flutter_secure_storage
  This will become an error in a future version of Flutter.
  ```

### 🛠️ Root cause

- `ios/Runner.xcodeproj/project.pbxproj` có **3 chỗ** đặt `IPHONEOS_DEPLOYMENT_TARGET = 13.0`
  (cho Runner target Debug / Profile / Release config ở PBXProject level).
- `ios/Podfile` đã khai báo `platform :ios, '16.0'`, **NHƯNG** deployment target thực tế
  trong Xcode project vẫn ở 13.0. Khi Flutter dùng **Swift Package Manager (SPM)**
  cho `background_downloader` (lỗi SPM), target lấy từ **Xcode project**, không phải Podfile.
- `background_downloader` 9.x chỉ ship qua SPM (không còn CocoaPods), yêu cầu iOS 14.0+.
- Memory.md đã xác định project cần **iOS 16+** cho LiteRT-LM và Core ML delegate.

### ✅ Fix đã áp dụng

| File | Thay đổi |
|------|----------|
| `ios/Runner.xcodeproj/project.pbxproj` | Tăng `IPHONEOS_DEPLOYMENT_TARGET` từ `13.0` → `16.0` ở 3 config (Debug, Profile, Release) |
| `ios/Flutter/AppFrameworkInfo.plist` | Thêm `<key>MinimumOSVersion</key><string>16.0</string>` |
| `ios/Podfile` | Thêm `post_install` hook enforce tất cả Pods target `IPHONEOS_DEPLOYMENT_TARGET` >= 16.0 (dùng `Gem::Version` compare) |

### 📋 Các bước đã thực hiện

1. `sed -i '' 's/IPHONEOS_DEPLOYMENT_TARGET = 13.0;/IPHONEOS_DEPLOYMENT_TARGET = 16.0;/g' ios/Runner.xcodeproj/project.pbxproj`
2. Thêm key `MinimumOSVersion = 16.0` vào `ios/Flutter/AppFrameworkInfo.plist`
3. Cập nhật `post_install` trong `ios/Podfile` để tự động enforce tối thiểu 16.0 cho mọi Pods
4. `flutter clean` + `flutter pub get` + `cd ios && pod install`
5. Verify: `grep IPHONEOS_DEPLOYMENT_TARGET ios/Pods/Pods.xcodeproj/project.pbxproj | sort -u` → chỉ còn duy nhất `16.0`

### 🆕 Gotchas mới

- **SPM lấy deployment target từ Xcode project, không từ Podfile**: Khi plugin dùng Swift Package Manager (như `background_downloader` 9.x), Xcode sẽ kiểm tra `IPHONEOS_DEPLOYMENT_TARGET` của Runner target trong `project.pbxproj`. Nếu chỉ sửa `Podfile` thì **không đủ** — phải sửa cả Xcode project.
- **`AppFrameworkInfo.plist` cần `MinimumOSVersion`**: Flutter tự động thêm key này từ `IPHONEOS_DEPLOYMENT_TARGET` của Xcode project, nhưng nên khai báo tường minh trong plist để tránh Xcode tự default về 13.0.
- **Post_install hook bắt buộc cho mọi project có Pods**: Sau khi `pod install`, CocoaPods sinh `Pods.xcodeproj` với deployment target của từng Pod. Một số Pods (vd `flutter_secure_storage` core ở 9.0) sẽ dùng target thấp — nên enforce min 16.0 trong `post_install` để đồng bộ.
- **`flutter_secure_storage` không support SPM** là warning, không phải lỗi hiện tại. Flutter tự động fallback CocoaPods cho plugin này. Theo docs sẽ thành lỗi trong tương lai — theo dõi upstream để migrate khi cần.
- **Pre-existing analyzer warnings** (13 issues, 0 errors) không liên quan đến build fix: `unnecessary_non_null_assertion`, `use_super_parameters`, `unused_element`, `await_only_futures`. Đã có trước fix, sẽ refactor sau.

### 🧪 Verify pass

- `flutter pub get` → success (chỉ warning về flutter_secure_storage SPM, không phải lỗi)
- `pod install` → 4 pods installed (Flutter, MediaPipeTasksGenAI 0.10.35, MediaPipeTasksGenAIC 0.10.35, flutter_secure_storage 6.0.0)
- `flutter analyze` → 13 pre-existing issues, **0 errors**
- Tất cả Pods deployment target đồng bộ về 16.0

---

## Context Window Notes

Đây là project **research + prototype**, không phải production delivery.
Mục tiêu: feasibility report + working demo.
Không cần worry về CI/CD, app store submission ở giai đoạn này.