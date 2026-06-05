# rules/rag.md — Offline RAG Pipeline

## Overview

RAG pipeline **100% offline**: không gọi bất kỳ API nào sau khi app đã cài đặt.

```
Document Input (PDF, TXT, MD)
        │
        ▼
   [Chunker]  → fixed-size + overlap
        │
        ▼
 [EmbeddingService]  → local model (Platform Channel)
        │
        ▼
   [VectorStore]  → SQLite + sqlite_vec (cosine similarity)
        │
   Query time:
        │
   [Retriever]  → embed query → search top-K → rerank
        │
        ▼
 [ContextBuilder]  → format retrieved chunks → prepend to prompt
```

---

## Embedding Model

### Option A: MiniLM via ONNX (Recommended)
- Model: `all-MiniLM-L6-v2` (~22MB, 384-dim vectors)
- Run qua ONNX Runtime Flutter plugin
- **Pros**: nhẹ, nhanh, chất lượng tốt cho tiếng Anh
- **Cons**: tiếng Việt trung bình

### Option B: Gemma Embedding (LiteRT)
- Dùng chung LiteRT-LM infrastructure
- **Pros**: cùng stack, hỗ trợ đa ngôn ngữ tốt hơn
- **Cons**: nặng hơn, chậm hơn

### Platform Channel — Embedding

```dart
abstract class EmbeddingService {
  Future<List<double>> embed(String text);
  Future<List<List<double>>> embedBatch(List<String> texts);
}
```

---

## Document Chunking

```dart
class TextChunker {
  final int chunkSize;      // default: 512 tokens (~350 words)
  final int overlapTokens;  // default: 64 tokens

  List<Chunk> chunk(String text, {String? docId}) {
    // Sliding window với overlap
    // Ưu tiên split ở ranh giới câu/đoạn
    // Giữ metadata: docId, chunkIndex, pageNumber
  }
}

class Chunk {
  final String id;          // "${docId}_${chunkIndex}"
  final String text;
  final Map<String, dynamic> metadata;
  List<double>? embedding;
}
```

---

## Vector Store (sqlite_vec)

### Setup

```yaml
# pubspec.yaml
dependencies:
  sqlite_async: ^0.x.x
  sqlite_vec: ^0.x.x        # SQLite vector extension
```

### Schema

```sql
CREATE TABLE documents (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  source TEXT,
  indexed_at INTEGER,
  chunk_count INTEGER
);

CREATE TABLE chunks (
  id TEXT PRIMARY KEY,
  doc_id TEXT REFERENCES documents(id),
  content TEXT NOT NULL,
  chunk_index INTEGER,
  metadata TEXT  -- JSON
);

-- sqlite_vec virtual table
CREATE VIRTUAL TABLE chunk_embeddings USING vec0(
  chunk_id TEXT PRIMARY KEY,
  embedding FLOAT[384]    -- MiniLM dimension
);
```

### Dart VectorStore API

```dart
class VectorStore {
  Future<void> addDocument(Document doc, List<Chunk> chunks);
  Future<List<SearchResult>> search(List<double> queryEmbedding, {int topK = 5});
  Future<void> deleteDocument(String docId);
  Future<List<Document>> listDocuments();
  Future<int> totalChunks();
}

class SearchResult {
  final Chunk chunk;
  final double score;       // cosine similarity 0-1
  final Document document;
}
```

---

## Retriever

```dart
class RagRetriever {
  final EmbeddingService _embedder;
  final VectorStore _store;

  Future<List<SearchResult>> retrieve(
    String query, {
    int topK = 5,
    double minScore = 0.5,
  }) async {
    final queryVec = await _embedder.embed(query);
    final results = await _store.search(queryVec, topK: topK * 2);

    // Filter by min score + deduplicate by doc
    return results
        .where((r) => r.score >= minScore)
        .take(topK)
        .toList();
  }
}
```

---

## Context Building

```dart
class ContextBuilder {
  static const int maxContextChars = 2000;

  String build(List<SearchResult> results, String userQuery) {
    if (results.isEmpty) return '';

    final buf = StringBuffer();
    buf.writeln('### Relevant context:');
    int total = 0;

    for (final r in results) {
      final snippet = r.chunk.text;
      if (total + snippet.length > maxContextChars) break;
      buf.writeln('---');
      buf.writeln('[Source: ${r.document.title}]');
      buf.writeln(snippet);
      total += snippet.length;
    }

    buf.writeln('---');
    buf.writeln('### Question: $userQuery');
    return buf.toString();
  }
}
```

---

## Indexing Flow (UI perspective)

1. User chọn file (PDF, TXT, MD) qua `file_picker`
2. Show progress dialog: "Đang đọc... → Đang chia nhỏ... → Đang tạo embeddings..."
3. Batch embed (hiển thị %) → lưu vào SQLite
4. Notify thành công + số chunks đã index

**Batch embedding để tránh UI freeze**:
```dart
// Chia thành batch 10 chunks, yield giữa các batch
for (var i = 0; i < chunks.length; i += 10) {
  final batch = chunks.skip(i).take(10).toList();
  await _embedder.embedBatch(batch.map((c) => c.text).toList());
  yield IndexProgress(current: i + batch.length, total: chunks.length);
  await Future.delayed(Duration.zero); // let UI breathe
}
```

---

## RAG + Chat Integration

```dart
// Trong ChatBloc
Future<String> _buildRagPrompt(String userMessage) async {
  // 1. Retrieve relevant chunks
  final results = await _retriever.retrieve(userMessage, topK: 3);

  // 2. Build augmented prompt
  if (results.isEmpty) return userMessage;  // no RAG context

  final context = _contextBuilder.build(results, userMessage);
  return context;
}
```

---

## Storage Limits

| Item | Size estimate |
|------|---------------|
| MiniLM model | ~22MB |
| 1000 chunks × 384-dim float32 | ~1.5MB |
| SQLite DB (text + metadata) | ~5MB per 100 docs |
| Total RAG overhead | < 30MB |
