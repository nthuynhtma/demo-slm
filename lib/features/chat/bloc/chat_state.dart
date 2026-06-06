import 'package:equatable/equatable.dart';
import '../models/chat_message.dart';

/// Possible statuses for the chat feature.
enum ChatStatus {
  /// Checking model status and document indexing status at startup.
  checkingStartup,

  /// Model is not downloaded yet; requires user download prompt/CTA.
  needsDownload,

  /// Ready to accept user input.
  ready,

  /// Waiting for model to load.
  loadingModel,

  /// Model is generating a response.
  generating,

  /// An error occurred.
  error,
}

/// State representation for the ChatBloc.
class ChatState extends Equatable {
  final ChatStatus status;
  final List<ChatMessage> messages;
  final String? errorMessage;
  final bool useRag;
  final bool isDownloading;
  final double downloadProgress;
  final bool isModelDownloaded;
  final bool isModelLoaded;
  final int documentCount;
  final double? indexingProgress;
  final bool isDownloadPaused;

  const ChatState({
    this.status = ChatStatus.checkingStartup,
    this.messages = const [],
    this.errorMessage,
    this.useRag = false,
    this.isDownloading = false,
    this.downloadProgress = 0.0,
    this.isModelDownloaded = false,
    this.isModelLoaded = false,
    this.documentCount = 0,
    this.indexingProgress,
    this.isDownloadPaused = false,
  });

  ChatState copyWith({
    ChatStatus? status,
    List<ChatMessage>? messages,
    String? errorMessage,
    bool clearError = false,
    bool? useRag,
    bool? isDownloading,
    double? downloadProgress,
    bool? isModelDownloaded,
    bool? isModelLoaded,
    int? documentCount,
    double? indexingProgress,
    bool clearIndexingProgress = false,
    bool? isDownloadPaused,
  }) {
    return ChatState(
      status: status ?? this.status,
      messages: messages ?? this.messages,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      useRag: useRag ?? this.useRag,
      isDownloading: isDownloading ?? this.isDownloading,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      isModelDownloaded: isModelDownloaded ?? this.isModelDownloaded,
      isModelLoaded: isModelLoaded ?? this.isModelLoaded,
      documentCount: documentCount ?? this.documentCount,
      indexingProgress: clearIndexingProgress ? null : (indexingProgress ?? this.indexingProgress),
      isDownloadPaused: isDownloadPaused ?? this.isDownloadPaused,
    );
  }

  @override
  List<Object?> get props => [
        status,
        messages,
        errorMessage,
        useRag,
        isDownloading,
        downloadProgress,
        isModelDownloaded,
        isModelLoaded,
        documentCount,
        indexingProgress,
        isDownloadPaused,
      ];
}

