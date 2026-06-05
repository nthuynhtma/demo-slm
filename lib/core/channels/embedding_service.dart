/// Abstract interface for generating text embeddings on-device.
///
/// Implementations can use MiniLM via ONNX Runtime (recommended),
/// Gemma embedding via LiteRT-LM, or a mock for testing.
abstract class EmbeddingService {
  /// Generate an embedding vector for a single [text].
  ///
  /// Returns a list of doubles (384-dim for MiniLM).
  /// Returns an empty list on failure.
  Future<List<double>> embed(String text);

  /// Generate embedding vectors for multiple texts in a batch.
  ///
  /// Batch embedding is more efficient than calling [embed] repeatedly
  /// as it reduces platform channel overhead.
  Future<List<List<double>>> embedBatch(List<String> texts);
}