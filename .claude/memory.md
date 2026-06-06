# memory.md — Claude's Project Notes

## Decisions Made

| Date | Decision | Reason |
|------|----------|--------|
| 2026-06 | LiteRT-LM thay vì llama.cpp | Official Google support, tích hợp tốt hơn với Android NNAPI + iOS Core ML |
| 2026-06 | sqlite_vec cho vector store | Lightweight, không cần server, tích hợp vào SQLite sẵn có |
| 2026-06 | MiniLM cho embedding | ~22MB, đủ chất lượng, nhanh hơn Gemma embedding |
| 2026-06 | flutter_bloc | Consistent với codebase TMA hiện tại |
| 2026-06 | **fonnx** cho ONNX runtime thay vì onnxruntime_flutter | fonnx actively maintained (last push 2026-05-22), onnxruntime_flutter stalled since Dec 2024 |
| 2026-06 | **LiteRT-LM 0.10.35 → 0.10.36** (nâng cấp) | 0.10.35 không support STABLEHLO_COMPOSITE op trong prefill_decode section, cần 0.10.36+ để tương thích với Gemma 4 E2B text-only .litertlm |
| 2026-06 | **iOS bridge dùng `LlmInference.Session` cho generation settings** | Với MediaPipeTasksGenAI 0.10.35, `temperature/topk` nằm ở session options, không nằm ở engine options |
| 2026-06 | **Băm SHA256 dạng stream để tránh OOM** | Tránh lỗi tràn bộ nhớ (OOM) khi băm file model nặng 2.6GB trên thiết bị di động |
| 2026-06 | **Resumable download qua Dio Range** | Hỗ trợ tải tiếp tục model 2.6GB bằng HTTP Range header để tăng độ ổn định |

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
- Litert-LM version hiện tại: **0.10.36** (nâng cấp từ 0.10.35 để fix STABLEHLO_COMPOSITE)

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

- **STABLEHLO_COMPOSITE lỗi prefill**: Model `.litertlm` chứa op MLIR `STABLEHLO_COMPOSITE` mà LiteRT-LM 0.10.35 không support với XNNPACK (CPU). Lỗi `prefill_runner->AllocateTensors() == kTfLiteOk (1 vs. 0)`. Cần LiteRT-LM 0.10.36+ để tương thích.
- **Version mismatch Android/iOS**: Android 0.10.22 quá cũ so với iOS 0.10.35. Đồng bộ lên 0.10.36 cả 2 platform.
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

## Context Window Notes

Đây là project **research + prototype**, không phải production delivery.
Mục tiêu: feasibility report + working demo.
Không cần worry về CI/CD, app store submission ở giai đoạn này.
