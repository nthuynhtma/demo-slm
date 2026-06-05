import '../../../core/channels/inference_service.dart';
import '../download/model_downloader.dart';

/// Service that orchestrates model lifecycle (download → load → dispose).
///
/// Wraps [ModelDownloader] and [InferenceService] to provide a unified
/// interface for model management.
class ModelLoader {
  final ModelDownloader _downloader;
  final InferenceService _inferenceService;
  bool _isLoaded = false;

  ModelLoader({
    required ModelDownloader downloader,
    required InferenceService inferenceService,
  })  : _downloader = downloader,
        _inferenceService = inferenceService;

  /// Whether the model is currently loaded and ready for inference.
  bool get isLoaded => _isLoaded;

  /// Ensure the model is downloaded and loaded.
  ///
  /// If the model is not yet downloaded, it will be fetched first.
  /// [onDownloadProgress] reports download progress (0.0 - 1.0).
  Future<void> ensureModelLoaded({
    void Function(double progress)? onDownloadProgress,
  }) async {
    if (_isLoaded) return;

    // Step 1: Get or download the model file
    final modelPath = await _downloader.getCachedModelPath();
    final path = modelPath ??
        await _downloader.downloadModel(onProgress: onDownloadProgress);

    // Step 2: Load the model into LiteRT-LM engine
    // loadModel() throws on failure
    await _inferenceService.loadModel(path);

    _isLoaded = true;
  }

  /// Unload the model and release resources.
  Future<void> unloadModel() async {
    if (!_isLoaded) return;
    await _inferenceService.dispose();
    _isLoaded = false;
  }

  /// Check device compatibility before loading.
  ///
  /// Returns a list of warning messages (empty if fully compatible).
  Future<List<String>> checkCompatibility() async {
    final warnings = <String>[];
    // Runtime checks would go here:
    // - Available RAM
    // - GPU delegate support
    // - Storage space
    return warnings;
  }
}