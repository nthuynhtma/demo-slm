import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path_provider/path_provider.dart';
import '../models/chunk.dart';
import '../models/document.dart';

// ── Persistence interface ──

/// Pluggable persistence backend for [VectorStore].
///
/// - Production: use [DiskVectorStorePersistence] (writes to ApplicationSupport via path_provider).
/// - Unit tests: use [NullVectorStorePersistence] to avoid path_provider binding requirement.
abstract interface class VectorStorePersistence {
  Future<void> save(Map<String, dynamic> data);
  Future<Map<String, dynamic>?> load();
}

/// Production backend — writes to `ApplicationSupport/rag_store.json`.
class DiskVectorStorePersistence implements VectorStorePersistence {
  static const String _fileName = 'rag_store.json';

  @override
  Future<void> save(Map<String, dynamic> data) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      stderr.writeln('DiskVectorStorePersistence.save error: $e');
    }
  }

  @override
  Future<Map<String, dynamic>?> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      stderr.writeln('DiskVectorStorePersistence.load error: $e');
      return null;
    }
  }
}

/// No-op backend for unit tests — never touches the file system.
class NullVectorStorePersistence implements VectorStorePersistence {
  @override
  Future<void> save(Map<String, dynamic> data) async {}

  @override
  Future<Map<String, dynamic>?> load() async => null;
}

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
  /// Persistence backend — injectable for testing.
  final VectorStorePersistence _persistence;

  VectorStore({VectorStorePersistence? persistence})
      : _persistence = persistence ?? DiskVectorStorePersistence();

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
    await saveToDisk();
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
    await saveToDisk();
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
    await saveToDisk();
  }

  // ── Persistence ──

  Map<String, dynamic> _documentToJson(Document doc) => {
        'id': doc.id,
        'title': doc.title,
        'source': doc.source,
        'indexedAt': doc.indexedAt,
        'chunkCount': doc.chunkCount,
      };

  Document _documentFromJson(Map<String, dynamic> json) => Document(
        id: json['id'] as String,
        title: json['title'] as String,
        source: json['source'] as String?,
        indexedAt: json['indexedAt'] as int,
        chunkCount: json['chunkCount'] as int? ?? 0,
      );

  Future<void> saveToDisk() async {
    final data = {
      'documents': _documents.values.map(_documentToJson).toList(),
      'chunks': _chunks.map((ic) => ic.chunk.toJson()).toList(),
    };
    await _persistence.save(data);
  }

  Future<void> loadFromDisk() async {
    final data = await _persistence.load();
    if (data == null) return;

    final docsList = data['documents'] as List<dynamic>;
    final chunksList = data['chunks'] as List<dynamic>;

    _documents.clear();
    _chunks.clear();

    for (final docJson in docsList) {
      final doc = _documentFromJson(docJson as Map<String, dynamic>);
      _documents[doc.id] = doc;
    }

    for (final chunkJson in chunksList) {
      final chunk = Chunk.fromJson(chunkJson as Map<String, dynamic>);
      _chunks.add(_IndexedChunk(
        chunk: chunk,
        docId: chunk.docId,
      ));
    }
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