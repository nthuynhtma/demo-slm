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

  const ChatState({
    this.status = ChatStatus.ready,
    this.messages = const [],
    this.errorMessage,
  });

  ChatState copyWith({
    ChatStatus? status,
    List<ChatMessage>? messages,
    String? errorMessage,
    bool clearError = false,
  }) {
    return ChatState(
      status: status ?? this.status,
      messages: messages ?? this.messages,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  @override
  List<Object?> get props => [status, messages, errorMessage];
}
