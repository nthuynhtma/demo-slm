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

/// Report an error that occurred during inference or download.
class ChatError extends ChatEvent {
  final String errorMessage;

  const ChatError(this.errorMessage);

  @override
  List<Object?> get props => [errorMessage];
}

/// Toggle RAG mode on/off.
class ToggleRag extends ChatEvent {
  const ToggleRag();
}

/// Explicitly trigger downloading of the model file.
class DownloadModel extends ChatEvent {
  const DownloadModel();
}

/// Update model download progress.
class DownloadProgressUpdate extends ChatEvent {
  final double progress;

  const DownloadProgressUpdate(this.progress);

  @override
  List<Object?> get props => [progress];
}

/// Delete the model file from local storage.
class DeleteModel extends ChatEvent {
  const DeleteModel();
}

/// Refresh the state of model downloading / loading status.
class RefreshModelStatus extends ChatEvent {
  const RefreshModelStatus();
}

/// Index a text document.
class IndexDocument extends ChatEvent {
  final String title;
  final String content;

  const IndexDocument({required this.title, required this.content});

  @override
  List<Object?> get props => [title, content];
}

/// Clear all indexed documents in the Vector Store.
class ClearIndex extends ChatEvent {
  const ClearIndex();
}

