import 'package:flutter/services.dart';

/// Platform channel wrapper for generating embeddings on-device.
///
/// Uses a local embedding model (e.g., MiniLM via ONNX Runtime)
/// exposed through native platform channels.
class EmbeddingChannel {
  static const String _channelName = 'com.demo.slm_app/embedding';

  final MethodChannel _methodChannel;

  EmbeddingChannel() : _methodChannel = const MethodChannel(_channelName);

  /// Load an embedding model from the given [modelPath].
  Future<bool> loadModel(String modelPath) async {
    final result = await _methodChannel.invokeMethod<bool>(
      'loadEmbeddingModel',
      {'modelPath': modelPath},
    );
    return result ?? false;
  }

  /// Generate an embedding vector for the given [text].
  ///
  /// Returns a list of floats representing the embedding.
  /// Returns an empty list on failure.
  Future<List<double>> embed(String text) async {
    final result = await _methodChannel.invokeMethod<List<double>>(
      'embed',
      {'text': text},
    );
    return result ?? [];
  }
}