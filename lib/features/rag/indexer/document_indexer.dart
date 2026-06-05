import 'dart:async';
import '../../../core/channels/embedding_service.dart';
import '../models/chunk.dart';
import '../models/document.dart';
import '../vector_store/vector_store.dart';
import 'text_chunker.dart';

/// Progress reported during the indexing process.
class IndexProgress {
  final int current;
  final int total;

  const IndexProgress({required this.current, required this.total});

  double get fraction => total > 0 ? current / total : 0.0;
}

/// Indexes documents end-to-end: chunk → embed → store.
///
/// Wraps [TextChunker], [EmbeddingService], and [VectorStore] into a
/// single pipeline with batch embedding and progress reporting.
///
/// Usage:
/// ```dart
/// await for (final progress in indexer.indexText('...', title: 'My Doc')) {
///   print('${progress.fraction * 100}%');
/// }
/// ```
class DocumentIndexer {
  final TextChunker _chunker;
  final EmbeddingService _embedder;
  final VectorStore _vectorStore;

  DocumentIndexer({
    TextChunker? chunker,
    required EmbeddingService embedder,
    required VectorStore vectorStore,
  })  : _chunker = chunker ?? const TextChunker(),
        _embedder = embedder,
        _vectorStore = vectorStore;

  /// Index a text document.
  ///
  /// Returns a [Stream] of [IndexProgress] updates so the UI can show progress.
  /// The stream completes when the entire document has been indexed.
  ///
  /// [text] is the full document text.
  /// [title] is a human-readable title for the document.
  /// [source] is optional metadata (e.g., file path or URL).
  Stream<IndexProgress> indexText(
    String text, {
    required String title,
    String? source,
  }) async* {
    final docId = _normalizeId(title);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Step 1: Chunk
    yield const IndexProgress(current: 0, total: 1);
    final chunkResults = _chunker.chunk(text, docId: docId);

    if (chunkResults.isEmpty) {
      yield const IndexProgress(current: 1, total: 1);
      return;
    }

    // Step 2: Embed in batches of 10
    final chunks = <Chunk>[];
    final totalChunks = chunkResults.length;

    for (int i = 0; i < totalChunks; i += 10) {
      final batch = chunkResults.skip(i).take(10).toList();

      // Embed batch
      final embeddings =
          await _embedder.embedBatch(batch.map((c) => c.text).toList());

      for (int j = 0; j < batch.length; j++) {
        chunks.add(Chunk(
          id: batch[j].id,
          docId: docId,
          text: batch[j].text,
          chunkIndex: batch[j].index,
          embedding: embeddings.length > j ? embeddings[j] : [],
        ));
      }

      yield IndexProgress(current: (i + batch.length).clamp(0, totalChunks),
          total: totalChunks);

      // Yield to let UI breathe between batches
      await Future.delayed(Duration.zero);
    }

    // Step 3: Store
    final doc = Document(
      id: docId,
      title: title,
      source: source,
      indexedAt: now,
    );
    await _vectorStore.addDocument(doc, chunks);

    yield IndexProgress(current: totalChunks, total: totalChunks);
  }

  /// Clear all indexed documents.
  Future<void> clearIndex() async {
    await _vectorStore.clear();
  }

  /// Number of indexed documents.
  Future<int> get documentCount async => _vectorStore.documentCount;

  /// Normalize a string to a valid document ID.
  static String _normalizeId(String title) {
    return title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_\-. ]'), '')
        .replaceAll(' ', '_')
        .replaceAll(RegExp(r'_+'), '_');
  }
}