import 'package:equatable/equatable.dart';

/// Events that can be dispatched to the ChatBloc.
sealed class ChatEvent extends Equatable {
  const ChatEvent();

  @override
  List<Object?> get props => [];
}

/// Send a user message and trigger model inference.
class SendMessage extends ChatEvent {
  final String message;

  const SendMessage(this.message);

  @override
  List<Object?> get props => [message];
}

/// Update the assistant's response in real-time during streaming.
class StreamToken extends ChatEvent {
  final String token;

  const StreamToken(this.token);

  @override
  List<Object?> get props => [token];
}

/// Mark the streaming response as complete.
class StreamComplete extends ChatEvent {
  const StreamComplete();
}

/// Clear the entire chat conversation.
class ClearChat extends ChatEvent {
  const ClearChat();
}

/// Report an error that occurred during inference.
class ChatError extends ChatEvent {
  final String errorMessage;

  const ChatError(this.errorMessage);

  @override
  List<Object?> get props => [errorMessage];
}
