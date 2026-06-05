import 'dart:math';
import 'embedding_service.dart';

/// Mock implementation of [EmbeddingService] for testing the RAG flow
/// without requiring an actual embedding model.
///
/// Generates deterministic random 384-dim vectors (MiniLM dimension).
/// Uses a seed based on text hash so same text always gets same vector.
class MockEmbeddingService implements EmbeddingService {
  static const int embeddingDim = 384;

  /// Cache for deterministic embeddings: text hash → vector
  final Map<int, List<double>> _cache = {};
  final Random _random = Random(42);

  @override
  Future<List<double>> embed(String text) async {
    // Simulate embedding latency (5-10ms)
    await Future.delayed(Duration(milliseconds: 5 + text.length % 5));

    final hash = text.hashCode;
    return _cache.putIfAbsent(hash, () => _generateRandomVector());
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async {
    // Simulate batch latency (slightly faster per item)
    await Future.delayed(Duration(
      milliseconds: 3 * texts.length,
    ));

    return texts.map((t) {
      final hash = t.hashCode;
      return _cache.putIfAbsent(hash, () => _generateRandomVector());
    }).toList();
  }

  /// Generate a random unit vector (normalized) for cosine similarity testing.
  List<double> _generateRandomVector() {
    // Use Box-Muller transform for normal distribution
    final vector = List.generate(embeddingDim, (_) {
      final u1 = _random.nextDouble();
      final u2 = _random.nextDouble();
      return sqrt(-2 * log(u1)) * cos(2 * pi * u2);
    });

    // Normalize to unit length
    final magnitude = sqrt(vector.fold(0.0, (sum, v) => sum + v * v));
    return vector.map((v) => v / magnitude).toList();
  }
}