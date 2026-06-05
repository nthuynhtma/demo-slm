/// Base exception for all app-related errors.
class AppException implements Exception {
  final String message;
  final String? code;

  AppException(this.message, {this.code});

  @override
  String toString() => 'AppException($code): $message';
}

/// Thrown when model loading fails (e.g., file not found, incompatible format).
class ModelLoadException extends AppException {
  ModelLoadException(String message, {String? code})
      : super(message, code: code ?? 'MODEL_LOAD_ERROR');
}

/// Thrown when the LiteRT-LM inference engine encounters an error.
class InferenceException extends AppException {
  InferenceException(String message, {String? code})
      : super(message, code: code ?? 'INFERENCE_ERROR');
}

/// Thrown when model download fails (e.g., network error, insufficient storage).
class DownloadException extends AppException {
  DownloadException(String message, {String? code})
      : super(message, code: code ?? 'DOWNLOAD_ERROR');
}

/// Thrown when the device does not meet hardware requirements.
class HardwareException extends AppException {
  HardwareException(String message, {String? code})
      : super(message, code: code ?? 'HARDWARE_ERROR');
}

/// Thrown when the RAG pipeline encounters an error.
class RagException extends AppException {
  RagException(String message, {String? code})
      : super(message, code: code ?? 'RAG_ERROR');
}