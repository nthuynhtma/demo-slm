import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import '../../../core/errors/app_exceptions.dart';

/// Handles downloading Gemma 4 E2B model files from HuggingFace.
///
/// Supports resumable downloads, progress tracking, storage check, and checksum verification.
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
  /// [expectedSha256] can be passed to verify file integrity.
  Future<String> downloadModel({
    String? url,
    String? expectedSha256,
    void Function(double progress)? onProgress,
  }) async {
    final modelUrl = url ?? defaultModelUrl;
    final dir = await getApplicationSupportDirectory();
    final fileName = 'gemma-4-E2B-it.litertlm';
    final filePath = '${dir.path}/$fileName';
    final tempFilePath = '$filePath.tmp';

    // 1. Check if final file already exists
    final finalFile = File(filePath);
    if (await finalFile.exists()) {
      if (expectedSha256 != null && expectedSha256.isNotEmpty) {
        final isValid = await verifyChecksum(filePath, expectedSha256);
        if (isValid) {
          await _secureStorage.write(key: 'model_path', value: filePath);
          return filePath;
        } else {
          // Corrupt model, delete and download again
          await finalFile.delete();
        }
      } else {
        await _secureStorage.write(key: 'model_path', value: filePath);
        return filePath;
      }
    }

    // 2. Validate storage space (>3GB free)
    final hasEnoughSpace = await _checkFreeSpace(3 * 1024 * 1024 * 1024);
    if (!hasEnoughSpace) {
      throw DownloadException(
        'Insufficient disk space. At least 3.0 GB of free space is required.',
        code: 'INSUFFICIENT_SPACE',
      );
    }

    try {
      final tempFile = File(tempFilePath);
      int existingBytes = 0;
      if (await tempFile.exists()) {
        existingBytes = await tempFile.length();
      }

      // 3. Initiate chunk-by-chunk download
      final response = await _dio.get<ResponseBody>(
        modelUrl,
        options: Options(
          responseType: ResponseType.stream,
          headers: existingBytes > 0 ? {'Range': 'bytes=$existingBytes-'} : null,
        ),
      );

      final fileAccess = await tempFile.open(mode: FileMode.writeOnlyAppend);
      final contentLengthHeaderList = response.data?.headers[HttpHeaders.contentLengthHeader];
      final serverContentLength = contentLengthHeaderList != null && contentLengthHeaderList.isNotEmpty
          ? contentLengthHeaderList.first
          : null;
      final totalBytes = serverContentLength != null
          ? int.parse(serverContentLength) + existingBytes
          : -1;

      int bytesReceived = existingBytes;

      await for (final chunk in response.data!.stream) {
        await fileAccess.writeFrom(chunk);
        bytesReceived += chunk.length;
        if (totalBytes != -1 && onProgress != null) {
          onProgress(bytesReceived / totalBytes);
        }
      }
      await fileAccess.close();

      // 4. Verify SHA256 checksum
      if (expectedSha256 != null && expectedSha256.isNotEmpty) {
        onProgress?.call(0.99); // visual cue that verification is happening
        final isValid = await verifyChecksum(tempFilePath, expectedSha256);
        if (!isValid) {
          await tempFile.delete();
          throw DownloadException(
            'Model checksum verification failed. The downloaded file might be corrupt.',
            code: 'CHECKSUM_MISMATCH',
          );
        }
      }

      // 5. Rename temporary file to final path
      await tempFile.rename(filePath);

      // Cache the path
      await _secureStorage.write(key: 'model_path', value: filePath);
      return filePath;
    } on DioException catch (e) {
      throw DownloadException(
        'Failed to download model: ${e.message}',
        code: 'DOWNLOAD_FAILED',
      );
    } catch (e) {
      if (e is DownloadException) rethrow;
      throw DownloadException(
        'Unexpected error downloading model: $e',
        code: 'UNKNOWN_DOWNLOAD_ERROR',
      );
    }
  }

  /// Check if a model file has been downloaded and exists on disk.
  Future<bool> isModelDownloaded() async {
    final path = await getCachedModelPath();
    if (path == null) return false;
    return await File(path).exists();
  }

  /// Get the cached model file path.
  ///
  /// Returns `null` if no model has been downloaded yet.
  Future<String?> getCachedModelPath() async {
    return await _secureStorage.read(key: 'model_path');
  }

  /// Delete the downloaded model file to free up storage.
  Future<bool> deleteModel() async {
    final path = await getCachedModelPath();
    if (path == null) return false;

    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
    final tempFile = File('$path.tmp');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
    await _secureStorage.delete(key: 'model_path');
    return true;
  }

  /// Verify model integrity using streaming SHA256 hashing to avoid OOM.
  Future<bool> verifyChecksum(String filePath, String expectedSha256) async {
    if (expectedSha256.isEmpty || expectedSha256 == 'TODO_FILL_AFTER_DOWNLOAD') {
      // Calculate and log for debug purposes, but bypass hard block
      try {
        final calculated = await _calculateSha256(File(filePath));
        stderr.writeln('Calculated model SHA-256: $calculated');
      } catch (_) {}
      return true;
    }

    try {
      final calculated = await _calculateSha256(File(filePath));
      return calculated.toLowerCase() == expectedSha256.toLowerCase();
    } catch (e) {
      return false;
    }
  }

  /// Calculate SHA-256 in a streaming fashion (OOM safe)
  Future<String> _calculateSha256(File file) async {
    final stream = file.openRead();
    final digest = await sha256.bind(stream).first;
    return digest.toString();
  }

  /// Check storage space before downloading
  Future<bool> _checkFreeSpace(int requiredBytes) async {
    try {
      if (Platform.isMacOS || Platform.isLinux) {
        final result = await Process.run('df', ['-k', '/']);
        if (result.exitCode == 0) {
          final lines = result.stdout.toString().split('\n');
          if (lines.length > 1) {
            final parts = lines[1].split(RegExp(r'\s+'));
            if (parts.length > 3) {
              final freeKb = int.tryParse(parts[3]);
              if (freeKb != null) {
                return (freeKb * 1024) >= requiredBytes;
              }
            }
          }
        }
      }
      return true;
    } catch (_) {
      return true;
    }
  }
}
