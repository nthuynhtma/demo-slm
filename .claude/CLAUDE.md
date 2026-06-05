# CLAUDE.md — Offline Chat Flutter (LiteRT-LM + Gemma 4 2B)

## Project Overview

Build a **fully offline AI chatbot** trên Flutter (Android + iOS) sử dụng:
- **Inference engine**: LiteRT-LM (Google) — thư viện inference nhẹ cho on-device LLM
- **Model**: Gemma 4 2B Instruct (`.task` format từ LiteRT-LM)
- **RAG**: Offline hoàn toàn — embeddings local, vector search in-memory/SQLite
- **Platform**: Android + iOS, production-ready

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
| Model | Gemma-4-2B-it (`.task` hoặc `.bin`) |
| Embedding | MiniLM / Gemma embedding local |
| Vector Store | sqlite_vec hoặc in-memory cosine |
| Storage | flutter_secure_storage, path_provider |
| Streaming | StreamController → UI |

---

## Key Constraints

- **Model size**: Gemma 4 2B ~2–3GB; phải hỗ trợ download on-demand + cache
- **Memory**: Cần ít nhất 4GB RAM trên device; graceful degradation nếu thiếu
- **iOS**: LiteRT-LM dùng Core ML delegate; cần Metal support
- **Android**: NNAPI delegate ưu tiên; fallback CPU
- **No network**: Sau khi download model, app hoạt động 100% offline
- **Context window**: Gemma 4 2B ~8K tokens; cần quản lý history cẩn thận

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
  - Confirmed: LiteRT-LM 0.10.22+ API (ListenableFuture pattern)
  - Model: Gemma 4 2B Instruct (`.task` format)
  - Android native bridge working
  
- [x] Platform Channel bridge (Android Kotlin) ✅
  - InferencePlugin.kt implemented & built successfully
  - Uses `LlmInference.generateResponseAsync(prompt)` → `ListenableFuture<String>`
  - EventChannel for token streaming to Dart
  - Methods: loadModel, startGeneration, cancelGeneration, resetSession, getModelInfo

- [ ] Platform Channel bridge (iOS Swift)
  - InferencePlugin.swift stub created (needs completion)
  - API: LiteRT-LM iOS SDK via MediaPipeTasksGenAI pod

- [ ] Model download + caching flow
  - ModelDownloader interface defined
  - Needs: HTTP download, progress tracking, checksum verification

- [ ] Streaming inference pipeline
  - Android: Full response via ListenableFuture, needs token-level streaming
  - Need to implement word-level splitting for UI streaming effect

- [ ] RAG pipeline (indexer + retriever)
  - Text chunker, vector store interfaces defined
  - Needs: EmbeddingService platform channel (Android/iOS ONNX or LiteRT)

- [ ] Chat UI với streaming
  - ChatBloc structure defined
  - Needs: UI widgets, message list, input handling

- [ ] Performance benchmark
  - First token latency target: < 3s
  - Throughput target: > 8 tokens/s

## Related Files

- `rules/inference.md` — chi tiết LiteRT-LM API, Platform Channel patterns
- `rules/rag.md` — RAG architecture, embedding, vector search
- `rules/flutter-patterns.md` — coding conventions, bloc patterns
- `agents/researcher.md` — agent nghiên cứu feasibility
- `skills/model-loader.md` — tái sử dụng model download logic
