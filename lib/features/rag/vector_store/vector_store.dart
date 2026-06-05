import 'dart:math';
import '../models/chunk.dart';
import '../models/document.dart';

/// Result of a vector search query.
class SearchResult {
  final Chunk chunk;
  final double score; // cosine similarity 0-1
  final Document document;

  SearchResult({
    required this.chunk,
    required this.score,
    required this.document,
  });
}

/// In-memory vector store for RAG embeddings.
///
/// Stores document metadata + chunk embeddings as float vectors and supports
/// cosine similarity search with minScore filtering.
///
/// This is a lightweight fallback for prototyping.
/// For production, replace with sqlite_vec + SQLite (see rules/rag.md schema).
class VectorStore {
  // In-memory storage
  final Map<String, Document> _documents = {};
  final List<_IndexedChunk> _chunks = [];

  /// Total number of indexed chunks.
  int get totalChunks => _chunks.length;

  /// Total number of indexed documents.
  int get documentCount => _documents.length;

  // ── Document CRUD ──

  /// Add a document with its chunks to the store.
  ///
  /// All chunks must have their [Chunk.embedding] populated.
  Future<void> addDocument(Document doc, List<Chunk> chunks) async {
    _documents[doc.id] = doc.copyWith(chunkCount: chunks.length);

    for (final chunk in chunks) {
      if (chunk.embedding == null) {
        throw ArgumentError('Chunk ${chunk.id} has no embedding. '
            'Call embedder.embed() first.');
      }
      _chunks.add(_IndexedChunk(
        chunk: chunk,
        docId: doc.id,
      ));
    }
  }

  /// Search for the top [topK] most similar chunks to [queryEmbedding].
  ///
  /// Results are filtered by [minScore] threshold and sorted by similarity
  /// (descending). Returns up to [topK] results.
  Future<List<SearchResult>> search(
    List<double> queryEmbedding, {
    int topK = 5,
    double minScore = 0.5,
  }) async {
    if (_chunks.isEmpty) return [];

    final scores = <_ScoredChunk>[];

    for (final indexed in _chunks) {
      final similarity =
          _cosineSimilarity(queryEmbedding, indexed.chunk.embedding!);
      if (similarity >= minScore) {
        scores.add(_ScoredChunk(indexed: indexed, score: similarity));
      }
    }

    // Sort by score descending
    scores.sort((a, b) => b.score.compareTo(a.score));

    // Take topK
    final topScores = scores.take(topK);

    final results = <SearchResult>[];
    for (final s in topScores) {
      final doc = _documents[s.indexed.docId];
      if (doc != null) {
        results.add(SearchResult(
          chunk: s.indexed.chunk,
          score: s.score,
          document: doc,
        ));
      }
    }

    return results;
  }

  /// Delete a document and all its chunks by [docId].
  Future<void> deleteDocument(String docId) async {
    _documents.remove(docId);
    _chunks.removeWhere((c) => c.docId == docId);
  }

  /// List all indexed documents.
  Future<List<Document>> listDocuments() async {
    return _documents.values.toList();
  }

  /// Search for similar chunks (alias for [search] with same signature).
  Future<List<SearchResult>> searchSimilar(
    List<double> queryEmbedding, {
    int topK = 5,
    double minScore = 0.5,
  }) {
    return search(queryEmbedding, topK: topK, minScore: minScore);
  }

  /// Clear all data.
  Future<void> clear() async {
    _documents.clear();
    _chunks.clear();
  }

  // ── Cosine Similarity ──

  static double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;

    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    final denominator = sqrt(normA) * sqrt(normB);
    if (denominator == 0) return 0.0;

    return dotProduct / denominator;
  }
}

// ── Internal types ──

class _IndexedChunk {
  final Chunk chunk;
  final String docId;

  _IndexedChunk({required this.chunk, required this.docId});
}

class _ScoredChunk {
  final _IndexedChunk indexed;
  final double score;

  _ScoredChunk({required this.indexed, required this.score});
}