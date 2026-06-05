# memory.md — Claude's Project Notes

## Decisions Made

| Date | Decision | Reason |
|------|----------|--------|
| 2026-06 | LiteRT-LM thay vì llama.cpp | Official Google support, tích hợp tốt hơn với Android NNAPI + iOS Core ML |
| 2026-06 | sqlite_vec cho vector store | Lightweight, không cần server, tích hợp vào SQLite sẵn có |
| 2026-06 | MiniLM cho embedding | ~22MB, đủ chất lượng, nhanh hơn Gemma embedding |
| 2026-06 | flutter_bloc | Consistent với codebase TMA hiện tại |
| 2026-06 | **fonnx** cho ONNX runtime thay vì onnxruntime_flutter | fonnx actively maintained (last push 2026-05-22), onnxruntime_flutter stalled since Dec 2024 |
| 2026-06 | **LiteRT-LM 0.10.35** là target version | Latest stable (April 2026), hỗ trợ streaming callback đầy đủ |
| 2026-06 | **iOS bridge dùng `LlmInference.Session` cho generation settings** | Với MediaPipeTasksGenAI 0.10.35, `temperature/topk` nằm ở session options, không nằm ở engine options |

## Open Questions — Research Results (2026-06)

### ✅ LiteRT-LM streaming via EventChannel
- **Status**: ✅ Confirmed
- `LlmInference.generateResponseAsync` có `setResultListener(partialResult, done)` trên Android
- iOS dùng `AsyncSequence` (Swift async stream)
- EventChannel Flutter có thể bridge được, nhưng **cần post callback về main thread** trước khi gọi `eventSink.success()`
- Litert-LM version hiện tại: **0.10.35** (April 2026)

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

## Context Window Notes

Đây là project **research + prototype**, không phải production delivery.
Mục tiêu: feasibility report + working demo.
Không cần worry về CI/CD, app store submission ở giai đoạn này.
