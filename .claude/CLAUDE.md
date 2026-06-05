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

## Current Status

- [ ] LiteRT-LM Flutter integration research
- [ ] Platform Channel bridge (Android Kotlin)
- [ ] Platform Channel bridge (iOS Swift)
- [ ] Model download + caching flow
- [ ] Streaming inference pipeline
- [ ] RAG pipeline (indexer + retriever)
- [ ] Chat UI với streaming
- [ ] Performance benchmark

## Related Files

- `rules/inference.md` — chi tiết LiteRT-LM API, Platform Channel patterns
- `rules/rag.md` — RAG architecture, embedding, vector search
- `rules/flutter-patterns.md` — coding conventions, bloc patterns
- `agents/researcher.md` — agent nghiên cứu feasibility
- `skills/model-loader.md` — tái sử dụng model download logic
