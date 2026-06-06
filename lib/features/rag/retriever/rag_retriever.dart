import '../../../core/channels/embedding_service.dart';
import '../vector_store/vector_store.dart';

/// Retrieves relevant context from indexed documents given a user query.
///
/// Implements the RAG retrieval pipeline from rules/rag.md:
///   query → embed → search top-K (×2) → filter by minScore → deduplicate → top-K
class RagRetriever {
  final EmbeddingService _embedder;
  final VectorStore _store;

  RagRetriever({
    required EmbeddingService embedder,
    required VectorStore store,
  })  : _embedder = embedder,
        _store = store;

  VectorStore get store => _store;

  /// Retrieve relevant context chunks for the given [query].
  ///
  /// [topK] controls the final number of results.
  /// [minScore] filters out low-relevance results (default 0.5).
  ///
  /// The search retrieves [topK] * 2 candidates, then filters + deduplicates.
  /// This gives better coverage while maintaining quality.
  Future<List<SearchResult>> retrieve(
    String query, {
    int topK = 5,
    double minScore = 0.5,
  }) async {
    final queryVec = await _embedder.embed(query);
    if (queryVec.isEmpty) return [];

    // Retrieve 2× candidates for better coverage before filtering
    final results = await _store.search(
      queryVec,
      topK: topK * 2,
      minScore: minScore,
    );

    // Deduplicate by document: if multiple chunks from same doc,
    // keep the highest-scoring one
    final seenDocs = <String>{};
    final deduplicated = <SearchResult>[];
    for (final result in results) {
      if (seenDocs.contains(result.document.id)) continue;
      seenDocs.add(result.document.id);
      deduplicated.add(result);
      if (deduplicated.length >= topK) break;
    }

    return deduplicated;
  }
}