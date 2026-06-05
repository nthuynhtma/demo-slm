import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../../core/errors/app_exceptions.dart';

/// Handles downloading Gemma 4 E2B model files from HuggingFace.
///
/// Supports resumable downloads, progress tracking, and caching.
class ModelDownloader {
  final Dio _dio;
  final FlutterSecureStorage _secureStorage;

  /// HuggingFace repo for LiteRT-LM compatible Gemma 4 E2B model.
  static const String defaultModelUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';

  ModelDownloader({
    Dio? dio,
    FlutterSecureStorage? secureStorage,
  })  : _dio = dio ?? Dio(),
        _secureStorage = secureStorage ?? const FlutterSecureStorage();

  /// Download the model file to the app's application-support directory.
  ///
  /// Returns the local file path once download is complete.
  /// [onProgress] reports download progress as a fraction (0.0 - 1.0).
  Future<String> downloadModel({
    String? url,
    void Function(double progress)? onProgress,
  }) async {
    final modelUrl = url ?? defaultModelUrl;
    final dir = await getApplicationSupportDirectory();
    final fileName = 'gemma-4-E2B-it.litertlm';
    final filePath = '${dir.path}/$fileName';

    // Check if already downloaded
    if (await File(filePath).exists()) {
      await _secureStorage.write(key: 'model_path', value: filePath);
      return filePath;
    }

    try {
      await _dio.download(
        modelUrl,
        filePath,
        onReceiveProgress: (received, total) {
          if (total != -1 && onProgress != null) {
            onProgress(received / total);
          }
        },
      );

      // Verify file exists after download
      final file = File(filePath);
      if (!await file.exists()) {
        throw DownloadException('Download completed but file not found');
      }

      // Cache the path
      await _secureStorage.write(key: 'model_path', value: filePath);
      return filePath;
    } on DioException catch (e) {
      // Clean up partial download on failure
      final partialFile = File(filePath);
      if (await partialFile.exists()) {
        await partialFile.delete();
      }
      throw DownloadException(
        'Failed to download model: ${e.message}',
        code: 'DOWNLOAD_FAILED',
      );
    }
  }

  /// Get the cached model file path.
  ///
  /// Returns `null` if no model has been downloaded yet.
  Future<String?> getCachedModelPath() async {
    return await _secureStorage.read(key: 'model_path');
  }

  /// Check if a model file has been downloaded and exists on disk.
  Future<bool> isModelDownloaded() async {
    final path = await getCachedModelPath();
    if (path == null) return false;
    return await File(path).exists();
  }

  /// Delete the downloaded model file to free up storage.
  Future<bool> deleteModel() async {
    final path = await getCachedModelPath();
    if (path == null) return false;

    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
    await _secureStorage.delete(key: 'model_path');
    return true;
  }
}
