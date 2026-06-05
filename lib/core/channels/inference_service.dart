import 'dart:async';

/// Information about the loaded model.
class ModelInfo {
  final String name;
  final int sizeBytes;
  final int contextLength;

  const ModelInfo({
    required this.name,
    required this.sizeBytes,
    required this.contextLength,
  });
}

/// Abstract interface for LiteRT-LM inference.
///
/// Follows the contract defined in rules/inference.md.
abstract class InferenceService {
  /// Load a model from the given [modelPath].
  ///
  /// [modelPath] is the absolute path to the `.litertlm` file on disk.
  Future<void> loadModel(String modelPath);

  /// Generate a streaming response for [prompt] with generation parameters.
  ///
  /// The caller is responsible for serializing any conversation history
  /// into [prompt] using the model's chat template.
  /// The returned stream emits partial result tokens.
  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 1024,
    double temperature = 0.7,
  });

  /// Cancel the current generation, if any.
  Future<void> cancelGeneration();

  /// Reset the session, clearing conversation context.
  Future<void> resetSession();

  /// Release all resources.
  Future<void> dispose();

  /// Get information about the loaded model.
  Future<ModelInfo> getModelInfo();
}
