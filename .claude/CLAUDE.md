# CLAUDE.md — Offline Chat Flutter (LiteRT-LM + Gemma 4 E2B)

## Project Overview

Build a **fully offline AI chatbot** tren Flutter (Android + iOS) su dung:
- **Inference engine**: LiteRT-LM (Google) — thư viện inference nhẹ cho on-device LLM
- **Model**: Gemma 4 E2B Instruct (`.litertlm` format cho mobile)
- **RAG**: Offline hoàn toàn — embeddings local, vector search in-memory/SQLite
- **Platform**: Android + iOS, muc tieu prototype + feasibility demo

---

## Architecture (High-Level)

```
Flutter UI Layer
    │
    ▼
ChatBloc (flutter_bloc)
    │
    ├──▶ InferenceService (Platform Channel) ──▶ [Native] LiteRT-LM
    │         • loadModel()
    │         • generateStream()
    │         • resetSession()
    │
    └──▶ RagService (Dart)
              • indexDocuments()
              • retrieveContext()   ──▶ EmbeddingService (Platform Channel)
              • VectorStore (SQLite / in-memory)
```

## Tech Stack

| Layer | Technology |
|-------|-----------|
| UI | Flutter 3.x, flutter_bloc |
| Inference | LiteRT-LM via Platform Channels |
| Model | Gemma-4-E2B-it (`.litertlm` cho mobile, `.task` cho web) |
| Embedding | MiniLM via fonnx / Gemma embedding local |
| Vector Store | sqlite_vec (preferred, alpha) hoặc in-memory cosine |
| Storage | flutter_secure_storage, path_provider |
| Streaming | StreamController → UI |

---

## Key Constraints

- **Model size**: Gemma 4 E2B ~2.6GB; phải hỗ trợ download on-demand + cache
- **Memory**: Cần ít nhất 4GB RAM trên device; graceful degradation nếu thiếu
- **iOS**: LiteRT-LM dùng Core ML delegate; cần Metal support
- **Android**: NNAPI delegate ưu tiên; fallback CPU
- **No network**: Sau khi download model, app hoạt động 100% offline
- **Context window**: Gemma 4 E2B ~8K tokens; cần quản lý history cẩn thận

---

## Project Structure (Flutter)

```
lib/
├── core/
│   ├── channels/
│   │   ├── inference_channel.dart     # Platform channel wrapper
│   │   └── embedding_channel.dart
│   └── errors/
├── features/
│   ├── chat/
│   │   ├── bloc/
│   │   ├── models/
│   │   └── screens/
│   ├── model_manager/
│   │   ├── download/
│   │   └── loader/
│   └── rag/
│       ├── indexer/
│       ├── retriever/
│       └── vector_store/
├── native/
│   ├── android/                       # Kotlin bridge
│   └── ios/                           # Swift bridge
```

---

## Current Status (June 5, 2026)

- [x] LiteRT-LM Flutter integration research ✅ 
  - Confirmed: LiteRT-LM 0.10.35 API
  - Model: Gemma 4 E2B Instruct (`.litertlm` cho mobile)
  - Source: `litert-community/gemma-4-E2B-it-litert-lm`
  - Android native bridge working
  - iOS native API shape validated from installed pod headers
  
- [x] Platform Channel bridge (Android Kotlin) ✅
  - InferencePlugin.kt implemented & built successfully
  - Uses `LlmInference.generateResponseAsync(prompt)` → `ListenableFuture<String>`
  - EventChannel for token streaming to Dart
  - Methods: loadModel, startGeneration, cancelGeneration, resetSession, getModelInfo

- [x] Platform Channel bridge (iOS Swift) ✅
  - Session-based generation aligned with `MediaPipeTasksGenAI 0.10.35`
  - Registrar-based Flutter plugin registration validated
  - `flutter build ios --debug --no-codesign` passed locally after bridge fixes

- [x] Model download + caching flow ✅
  - ModelDownloader with resumable download, progress, space checks, and SHA256 verification.

- [x] Streaming inference pipeline ✅
  - Integrated streaming token delivery, cancellation UX, and animated cursors.

- [x] RAG pipeline (indexer + retriever) ✅
  - Chunker, VectorStore (in-memory persistent fallback), and Retriever integrated with prompt builder.

- [x] Chat UI với streaming ✅
  - Full ChatBloc state management, chat screen message bubble, and configuration drawer.

- [ ] Performance benchmark
  - First token latency target: < 3s
  - Throughput target: > 8 tokens/s

## Related Files

- `rules/inference.md` — chi tiết LiteRT-LM API, Platform Channel patterns
- `rules/rag.md` — RAG architecture, embedding, vector search
- `rules/flutter-patterns.md` — coding conventions, bloc patterns
- `rules/android-setup.md` / `rules/ios-setup.md` — platform setup chi tiet
- `agents/researcher.md` — agent nghiên cứu feasibility
- `skills/model-loader.md` — tái sử dụng model download logic
- `skills/ios-litert-bridge.md` — reusable fix pattern cho iOS bridge
