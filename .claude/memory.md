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

## Open Questions — Research Results (2026-06)

### ✅ LiteRT-LM streaming via EventChannel
- **Status**: ✅ Confirmed
- `LlmInference.generateResponseAsync` có `setResultListener(partialResult, done)` trên Android
- iOS dùng `AsyncSequence` (Swift async stream)
- EventChannel Flutter có thể bridge được, nhưng **cần post callback về main thread** trước khi gọi `eventSink.success()`
- Litert-LM version hiện tại: **0.10.35** (April 2026)

### ✅ Gemma 4 2B `.task` file availability
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

- LiteRT-LM callback KHÔNG chạy trên main thread → phải post về main thread trước khi update eventSink
- Gemma chat template dùng `<start_of_turn>` / `<end_of_turn>`, không phải `[INST]` hay `<|user|>`
- **Model Gemma 4 E2B không bị gated trên `litert-community` repo** (Apache 2.0), nhưng repo gốc `google/gemma-4-E2B-it` có thể gated
- Android emulator không có GPU/NNAPI → luôn test trên physical device
- iOS Simulator cũng không support Core ML delegate → cần physical device iOS
- `sqlite_vec` Flutter package rất alpha (0.1.7-alpha.3) → cần fallback plan
- LiteRT-LM 0.10.x dùng **`.litertlm`** format mới, không còn `.task` cho mobile (`.task` chỉ dành cho Web)
- Gemma 4 E2B dùng **SentencePiece**, không phải tiktoken
- iOS không support background streaming → cần save session state khi app进入 background

## Context Window Notes

Đây là project **research + prototype**, không phải production delivery.
Mục tiêu: feasibility report + working demo.
Không cần worry về CI/CD, app store submission ở giai đoạn này.
