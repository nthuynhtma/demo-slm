import 'package:equatable/equatable.dart';
import '../../model_manager/download/model_downloader.dart';

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

/// Explicitly load a downloaded model into memory without sending a chat message.
class PreloadModel extends ChatEvent {
  const PreloadModel();
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

/// Stop the active generation and keep any partial text that already streamed.
class CancelGeneration extends ChatEvent {
  const CancelGeneration();
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

/// Initialize the application and check model + RAG status on startup.
class StartupRequested extends ChatEvent {
  const StartupRequested();
}

/// App was backgrounded.
class AppBackgrounded extends ChatEvent {
  const AppBackgrounded();
}

/// App returned to the foreground.
class AppForegrounded extends ChatEvent {
  const AppForegrounded();
}

/// Flush buffered tokens to the UI state.
class FlushTokens extends ChatEvent {
  const FlushTokens();
}

/// Pause the active background model download.
class PauseModelDownload extends ChatEvent {
  const PauseModelDownload();
}

/// Resume the paused background model download.
class ResumeModelDownload extends ChatEvent {
  const ResumeModelDownload();
}

/// Cancel the active model download.
class CancelModelDownload extends ChatEvent {
  const CancelModelDownload();
}

/// Event triggered when a background download update is received.
class DownloadUpdateReceived extends ChatEvent {
  final double progress;
  final ModelDownloadStatus status;
  final String? errorMessage;

  const DownloadUpdateReceived({
    required this.progress,
    required this.status,
    this.errorMessage,
  });

  @override
  List<Object?> get props => [progress, status, errorMessage];
}
