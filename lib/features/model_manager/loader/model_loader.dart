import 'dart:io';

import '../../../core/channels/inference_service.dart';
import '../../../core/errors/app_exceptions.dart';
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

  /// Stream of model download progress & status updates.
  Stream<ModelDownloadUpdate> get downloadUpdates => _downloader.downloadUpdates;

  /// Check if a download task is currently active or paused.
  Future<ModelDownloadUpdate> getActiveDownloadUpdate() => _downloader.getActiveDownloadUpdate();

  /// Check if the model file exists on disk.
  Future<bool> isModelDownloaded() async {
    return await _downloader.isModelDownloaded();
  }

  /// Ensure the model is downloaded and loaded.
  ///
  /// Throws [ModelNotDownloadedException] if the model has not been
  /// downloaded yet. Callers (e.g. ChatBloc) are responsible for
  /// checking [isModelDownloaded] first and prompting the user before
  /// calling this method.
  Future<void> ensureModelLoaded({
    void Function(double progress)? onDownloadProgress,
  }) async {
    if (_isLoaded) return;

    // Step 1: Check that the model file exists on disk
    final hasDownloadedModel = await _downloader.isModelDownloaded();
    if (!hasDownloadedModel) {
      throw ModelNotDownloadedException();
    }
    // Step 2: Path is non-null because isModelDownloaded() returned true above
    final path = (await _downloader.getCachedModelPath())!;

    // Step 2b: Validate file size before attempting native load
    final file = File(path);
    if (!await file.exists()) {
      throw ModelLoadException('Model file not found at path: $path');
    }
    
    final fileSize = await file.length();
    const expectedSize = ModelDownloader.expectedModelSize;
    if (fileSize != expectedSize) {
      // Log warning but don't fail - the downloader should have validated this
      // ignore: avoid_print
      print('[ModelLoader] WARNING: Model file size mismatch (got $fileSize bytes, expected $expectedSize bytes)');
    }

    // Step 3: Load the model into LiteRT-LM engine
    // loadModel() throws on failure
    try {
      // ignore: avoid_print
      print('[ModelLoader] Loading model into native engine: $path');
      await _inferenceService.loadModel(path);
      // ignore: avoid_print
      print('[ModelLoader] Native model load complete');
    } catch (e) {
      // ignore: avoid_print
      print('[ModelLoader] Native model load failed: $e');
      // Wrap native errors with more context
      if (e.toString().contains('LOAD_FAILED') || e.toString().contains('LOAD_FAILED_CRITICAL')) {
        rethrow; // Already has good error message from native
      }
      throw ModelLoadException('Failed to load model into LiteRT-LM engine: $e');
    }

    _isLoaded = true;
  }

  /// Unload the model and release resources.
  Future<void> unloadModel() async {
    if (!_isLoaded) return;
    await _inferenceService.dispose();
    _isLoaded = false;
  }

  /// Delete the model file from disk after unloading it.
  Future<bool> deleteModel() async {
    await unloadModel();
    return await _downloader.deleteModel();
  }

  /// Download the model file without loading it.
  Future<void> downloadModel({
    String? url,
    String? expectedSha256,
  }) async {
    await _downloader.downloadModel(url: url, expectedSha256: expectedSha256);
  }

  Future<void> pauseDownload() => _downloader.pauseDownload();

  Future<void> resumeDownload() => _downloader.resumeDownload();

  Future<void> cancelDownload() => _downloader.cancelDownload();

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
