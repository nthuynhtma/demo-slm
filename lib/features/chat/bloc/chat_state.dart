import 'package:equatable/equatable.dart';
import '../models/chat_message.dart';

/// Possible statuses for the chat feature.
enum ChatStatus {
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

  const ChatState({
    this.status = ChatStatus.ready,
    this.messages = const [],
    this.errorMessage,
    this.useRag = false,
    this.isDownloading = false,
    this.downloadProgress = 0.0,
    this.isModelDownloaded = false,
    this.isModelLoaded = false,
    this.documentCount = 0,
    this.indexingProgress,
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
      ];
}

