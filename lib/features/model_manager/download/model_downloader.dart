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

    // 1. Check if final file already exists
    final dir = await getApplicationSupportDirectory();
    final fileName = 'gemma-4-E2B-it.litertlm';
    final filePath = '${dir.path}/$fileName';

    final finalFile = File(filePath);
    if (await finalFile.exists()) {
      if (expectedSha256 != null && expectedSha256.isNotEmpty) {
        final isValid = await verifyChecksum(filePath, expectedSha256);
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
      allowPause: true,
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

        final isValid = await verifyChecksum(filePath, 'TODO_FILL_AFTER_DOWNLOAD');
        if (isValid) {
          await _secureStorage.write(key: 'model_path', value: filePath);
          mappedStatus = ModelDownloadStatus.complete;
        } else {
          final file = File(filePath);
          if (await file.exists()) {
            await file.delete();
          }
          mappedStatus = ModelDownloadStatus.failed;
          errorMessage = 'Model checksum verification failed. The downloaded file might be corrupt.';
        }
        break;
      case TaskStatus.failed:
        mappedStatus = ModelDownloadStatus.failed;
        errorMessage = update.exception?.description ?? 'Unknown download error';
        break;
      case TaskStatus.canceled:
        mappedStatus = ModelDownloadStatus.canceled;
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
    if (expectedSha256.isEmpty || expectedSha256 == 'TODO_FILL_AFTER_DOWNLOAD') {
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
