import 'dart:async';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import '../../../core/errors/app_exceptions.dart';

enum ModelDownloadStatus {
  none,
  enqueued,
  downloading,
  paused,
  complete,
  failed,
  canceled,
}

class ModelDownloadUpdate {
  final ModelDownloadStatus status;
  final double progress;
  final String? errorMessage;

  const ModelDownloadUpdate({
    required this.status,
    required this.progress,
    this.errorMessage,
  });
}

/// Handles downloading Gemma 4 E2B model files from HuggingFace.
///
/// Uses background_downloader to manage downloads natively in the background,
/// enabling downloads to survive app suspension/termination.
class ModelDownloader {
  final FlutterSecureStorage _secureStorage;
  final StreamController<ModelDownloadUpdate> _updatesController =
      StreamController<ModelDownloadUpdate>.broadcast();

  static const String taskId = 'gemma_4_e2b_download';

  /// HuggingFace repo for LiteRT-LM compatible Gemma 4 E2B model.
  static const String defaultModelUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';

  /// Expected SHA256 checksum for the model file (gemma-4-E2B-it.litertlm)
  /// From HuggingFace LFS metadata: oid = 181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c
  static const String expectedModelSha256 =
      '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c';

  /// Expected file size in bytes (~2.59 GB)
  static const int expectedModelSize = 2588147712;

  ModelDownloader({
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  Stream<ModelDownloadUpdate> get downloadUpdates => _updatesController.stream;

  ModelDownloadUpdate _lastUpdate =
      const ModelDownloadUpdate(status: ModelDownloadStatus.none, progress: 0.0);

  ModelDownloadUpdate get lastUpdate => _lastUpdate;

  /// Initialize the downloader, track running tasks, and configure notifications.
  Future<void> initialize() async {
    // Configure notifications for background download progress
    await FileDownloader().configureNotification(
      running: const TaskNotification(
        'Tải model Gemma 4 E2B',
        'Đang tải... {progress}',
      ),
      complete: const TaskNotification(
        'Tải hoàn tất',
        'Model Gemma 4 E2B đã được tải thành công',
      ),
      error: const TaskNotification(
        'Tải thất bại',
        'Lỗi khi tải model Gemma 4 E2B',
      ),
      paused: const TaskNotification(
        'Tạm dừng tải',
        'Tiến trình tải model đã bị tạm dừng',
      ),
      progressBar: true,
    );

    // Track active/completed tasks enqueued in background
    await FileDownloader().trackTasks();

    // Clean up stale model path if file was deleted externally
    final savedPath = await getCachedModelPath();
    if (savedPath != null) {
      if (!await File(savedPath).exists()) {
        stderr.writeln('[ModelDownloader] Stale model path found, clearing: $savedPath');
        await _secureStorage.delete(key: 'model_path');
      }
    }

    // Listen to background downloader updates
    FileDownloader().updates.listen((update) {
      if (update.task.taskId != taskId) return;

      if (update is TaskStatusUpdate) {
        _handleStatusUpdate(update);
      } else if (update is TaskProgressUpdate) {
        _handleProgressUpdate(update);
      }
    });
  }

  /// Check if a download task is currently active or paused.
  Future<ModelDownloadUpdate> getActiveDownloadUpdate() async {
    final tasks = await FileDownloader().allTasks();
    Task? task;
    for (final t in tasks) {
      if (t.taskId == taskId) {
        task = t;
        break;
      }
    }

    if (task != null) {
      final record = await FileDownloader().database.recordForId(taskId);
      if (record != null) {
        final status = record.status;
        ModelDownloadStatus mappedStatus = ModelDownloadStatus.none;
        if (status == TaskStatus.running) {
          mappedStatus = ModelDownloadStatus.downloading;
        } else if (status == TaskStatus.enqueued) {
          mappedStatus = ModelDownloadStatus.enqueued;
        } else if (status == TaskStatus.paused) {
          mappedStatus = ModelDownloadStatus.paused;
        }

        _lastUpdate = ModelDownloadUpdate(
          status: mappedStatus,
          progress: record.progress.clamp(0.0, 1.0),
        );
        return _lastUpdate;
      }
    }
    return const ModelDownloadUpdate(status: ModelDownloadStatus.none, progress: 0.0);
  }

  /// Initiates or resumes the background download task.
  Future<void> downloadModel({
    String? url,
    String? expectedSha256,
  }) async {
    final modelUrl = url ?? defaultModelUrl;
    final checksum = expectedSha256 ?? expectedModelSha256;

    // 1. Check if final file already exists and is valid
    final dir = await getApplicationSupportDirectory();
    final fileName = 'gemma-4-E2B-it.litertlm';
    final filePath = '${dir.path}/$fileName';

    final finalFile = File(filePath);
    if (await finalFile.exists()) {
      // Validate file size first (fast check)
      final fileSize = await finalFile.length();
      if (fileSize != expectedModelSize) {
        // Size mismatch, delete and re-download
        await finalFile.delete();
      } else if (checksum.isNotEmpty) {
        // Size matches, verify checksum
        final isValid = await verifyChecksum(filePath, checksum);
        if (isValid) {
          await _secureStorage.write(key: 'model_path', value: filePath);
          _emitUpdate(ModelDownloadStatus.complete, 1.0);
          return;
        } else {
          // Corrupt model, delete
          await finalFile.delete();
        }
      } else {
        await _secureStorage.write(key: 'model_path', value: filePath);
        _emitUpdate(ModelDownloadStatus.complete, 1.0);
        return;
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

    // 3. Define the download task
    final task = DownloadTask(
      taskId: taskId,
      url: modelUrl,
      filename: fileName,
      baseDirectory: BaseDirectory.applicationSupport,
      updates: Updates.statusAndProgress,
      retries: 3,
      requiresWiFi: false, // User explicitly commented "ko" to wifi limitation
      metaData: 'with-notification',
      allowPause: true,
      priority: 0,
    );

    // 4. Check if task is already running
    final activeTasks = await FileDownloader().allTasks();
    bool isAlreadyRunning = false;
    for (final t in activeTasks) {
      if (t.taskId == taskId) {
        isAlreadyRunning = true;
        break;
      }
    }

    if (isAlreadyRunning) {
      final record = await FileDownloader().database.recordForId(taskId);
      if (record != null && record.status == TaskStatus.paused) {
        await FileDownloader().resume(task);
      }
      return;
    }

    // 5. Enqueue or resume the task
    final record = await FileDownloader().database.recordForId(taskId);
    bool success;
    if (record != null && record.status == TaskStatus.paused) {
      success = await FileDownloader().resume(task);
    } else {
      success = await FileDownloader().enqueue(task);
    }

    if (!success) {
      throw DownloadException(
        'Failed to start background download task.',
        code: 'DOWNLOAD_START_FAILED',
      );
    }

    _emitUpdate(ModelDownloadStatus.enqueued, 0.0);
  }

  Future<void> pauseDownload() async {
    await FileDownloader().pause(_buildTask());
  }

  Future<void> resumeDownload() async {
    await FileDownloader().resume(_buildTask());
  }

  Future<void> cancelDownload() async {
    await FileDownloader().cancelTasksWithIds([taskId]);
    _emitUpdate(ModelDownloadStatus.canceled, 0.0);
  }

  DownloadTask _buildTask({String? url}) {
    return DownloadTask(
      taskId: taskId,
      url: url ?? defaultModelUrl,
      filename: 'gemma-4-E2B-it.litertlm',
      baseDirectory: BaseDirectory.applicationSupport,
      updates: Updates.statusAndProgress,
      retries: 3,
      requiresWiFi: false,
      allowPause: true,
    );
  }

  Future<void> _handleStatusUpdate(TaskStatusUpdate update) async {
    final status = update.status;
    ModelDownloadStatus mappedStatus;
    String? errorMessage;

    // Log the status change for debugging
    stderr.writeln('[ModelDownloader] Status update: ${update.task.taskId} -> $status');

    switch (status) {
      case TaskStatus.enqueued:
        mappedStatus = ModelDownloadStatus.enqueued;
        break;
      case TaskStatus.running:
        mappedStatus = ModelDownloadStatus.downloading;
        break;
      case TaskStatus.paused:
        mappedStatus = ModelDownloadStatus.paused;
        break;
      case TaskStatus.complete:
        final dir = await getApplicationSupportDirectory();
        final filePath = '${dir.path}/gemma-4-E2B-it.litertlm';

        // Verify file existence
        final file = File(filePath);
        if (!await file.exists()) {
          mappedStatus = ModelDownloadStatus.failed;
          errorMessage = 'File model không tìm thấy sau khi tải xong tại: $filePath';
          stderr.writeln('[ModelDownloader] ERROR: $errorMessage');
          break;
        }

        // Verify file size
        final fileSize = await file.length();
        if (fileSize != expectedModelSize) {
          mappedStatus = ModelDownloadStatus.failed;
          errorMessage = 'Kích thước file không khớp (mong đợi $expectedModelSize bytes, nhận được $fileSize). File có thể bị lỗi.';
          stderr.writeln('[ModelDownloader] ERROR: $errorMessage');
          await file.delete();
          break;
        }

        // Verify checksum
        stderr.writeln('[ModelDownloader] Đang xác thực checksum...');
        final isValid = await verifyChecksum(filePath, expectedModelSha256);
        if (isValid) {
          await _secureStorage.write(key: 'model_path', value: filePath);
          mappedStatus = ModelDownloadStatus.complete;
          stderr.writeln('[ModelDownloader] Tải và xác thực model thành công.');
        } else {
          if (await file.exists()) {
            await file.delete();
          }
          mappedStatus = ModelDownloadStatus.failed;
          errorMessage = 'Xác thực checksum thất bại. File tải về có thể đã bị hỏng trong quá trình truyền tải.';
          stderr.writeln('[ModelDownloader] ERROR: $errorMessage');
        }
        break;
      case TaskStatus.failed:
        mappedStatus = ModelDownloadStatus.failed;
        final exception = update.exception;
        if (exception != null) {
          errorMessage = 'Lỗi tải xuống: ${exception.description}';
        } else {
          errorMessage = 'Lỗi tải xuống không xác định';
        }
        stderr.writeln('[ModelDownloader] ERROR: $errorMessage');
        break;
      case TaskStatus.canceled:
        mappedStatus = ModelDownloadStatus.canceled;
        stderr.writeln('[ModelDownloader] Tải xuống đã bị hủy.');
        break;
      case TaskStatus.notFound:
        mappedStatus = ModelDownloadStatus.failed;
        errorMessage = 'Không tìm thấy tác vụ tải xuống hoặc file trên server.';
        stderr.writeln('[ModelDownloader] ERROR: $errorMessage');
        break;
      default:
        mappedStatus = ModelDownloadStatus.none;
    }

    _emitUpdate(mappedStatus, _lastUpdate.progress, errorMessage);
  }

  void _handleProgressUpdate(TaskProgressUpdate update) {
    if (_lastUpdate.status == ModelDownloadStatus.complete) return;
    final progress = update.progress.clamp(0.0, 1.0);
    _emitUpdate(_lastUpdate.status, progress);
  }

  void _emitUpdate(ModelDownloadStatus status, double progress, [String? errorMessage]) {
    _lastUpdate = ModelDownloadUpdate(
      status: status,
      progress: progress,
      errorMessage: errorMessage,
    );
    _updatesController.add(_lastUpdate);
  }

  /// Check if a model file has been downloaded and exists on disk.
  Future<bool> isModelDownloaded() async {
    final path = await getCachedModelPath();
    if (path == null) return false;
    final file = File(path);
    if (!await file.exists()) return false;
    // Quick size validation
    final size = await file.length();
    return size == expectedModelSize;
  }

  /// Get the cached model file path.
  ///
  /// Returns `null` if no model has been downloaded yet.
  Future<String?> getCachedModelPath() async {
    return await _secureStorage.read(key: 'model_path');
  }

  /// Delete the downloaded model file to free up storage.
  Future<bool> deleteModel() async {
    await cancelDownload();
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
    if (expectedSha256.isEmpty) {
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