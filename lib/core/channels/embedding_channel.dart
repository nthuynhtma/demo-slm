import 'package:flutter/services.dart';
import 'embedding_service.dart';

/// Platform channel wrapper for generating embeddings on-device.
///
/// Uses a local embedding model (e.g., MiniLM via ONNX Runtime)
/// exposed through native platform channels.
class EmbeddingChannel implements EmbeddingService {
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
  @override
  Future<List<double>> embed(String text) async {
    final result = await _methodChannel.invokeMethod<List<dynamic>>('embed', {
      'text': text,
    });
    return _toVector(result);
  }

  /// Generate embeddings for a batch of texts.
  ///
  /// Falls back to per-item calls when the native side has not implemented
  /// a dedicated batch method yet.
  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async {
    try {
      final result = await _methodChannel.invokeMethod<List<dynamic>>(
        'embedBatch',
        {'texts': texts},
      );
      if (result == null) {
        return Future.wait(texts.map(embed));
      }

      return result
          .map((entry) => _toVector(entry as List<dynamic>?))
          .toList();
    } on MissingPluginException {
      return Future.wait(texts.map(embed));
    } on PlatformException {
      return Future.wait(texts.map(embed));
    }
  }

  /// Convert a dynamic platform channel payload into a Dart double vector.
  List<double> _toVector(List<dynamic>? values) {
    if (values == null) return const [];
    return values
        .map((value) => (value as num).toDouble())
        .toList(growable: false);
  }
}
