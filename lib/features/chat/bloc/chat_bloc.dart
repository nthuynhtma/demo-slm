import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../../../core/channels/inference_service.dart';

import '../models/chat_message.dart';
import 'chat_event.dart';
import 'chat_state.dart';

/// Business logic component for the chat feature.
///
/// Manages the conversation state, handles model inference via
/// [InferenceService], and processes streaming token updates.
class ChatBloc extends Bloc<ChatEvent, ChatState> {
  final InferenceService _inferenceService;
  final Uuid _uuid = const Uuid();
  StreamSubscription<String>? _inferenceSubscription;

  ChatBloc({required InferenceService inferenceService})
    : _inferenceService = inferenceService,
      super(const ChatState()) {
    on<SendMessage>(_onSendMessage);
    on<StreamToken>(_onStreamToken);
    on<StreamComplete>(_onStreamComplete);
    on<ClearChat>(_onClearChat);
    on<ChatError>(_onChatError);
  }

  Future<void> _onSendMessage(
    SendMessage event,
    Emitter<ChatState> emit,
  ) async {
    if (event.message.trim().isEmpty) return;

    // Add user message
    final userMessage = ChatMessage(
      id: _uuid.v4(),
      text: event.message,
      role: MessageRole.user,
      timestamp: DateTime.now(),
    );

    // Create placeholder for assistant response
    final assistantMessage = ChatMessage(
      id: _uuid.v4(),
      text: '',
      role: MessageRole.assistant,
      timestamp: DateTime.now(),
      isStreaming: true,
    );

    emit(
      state.copyWith(
        status: ChatStatus.generating,
        messages: [...state.messages, userMessage, assistantMessage],
      ),
    );

    try {
      // Subscribe to streaming inference
      final stream = _inferenceService.generateStream(prompt: event.message);
      await _inferenceSubscription?.cancel();
      _inferenceSubscription = stream.listen(
        (token) {
          add(StreamToken(token));
        },
        onDone: () {
          add(const StreamComplete());
        },
        onError: (error) {
          add(ChatError(error.toString()));
        },
      );
    } catch (e) {
      add(ChatError(e.toString()));
    }
  }

  void _onStreamToken(StreamToken event, Emitter<ChatState> emit) {
    final messages = state.messages;
    if (messages.isEmpty) return;

    final lastMessage = messages.last;
    if (!lastMessage.isStreaming) return;

    // Append token to the last assistant message
    final updatedMessages = [
      ...messages.sublist(0, messages.length - 1),
      lastMessage.copyWith(text: lastMessage.text + event.token),
    ];

    emit(state.copyWith(messages: updatedMessages));
  }

  void _onStreamComplete(StreamComplete event, Emitter<ChatState> emit) {
    final messages = state.messages;
    if (messages.isEmpty) return;

    final lastMessage = messages.last;
    if (!lastMessage.isStreaming) return;

    final updatedMessages = [
      ...messages.sublist(0, messages.length - 1),
      lastMessage.copyWith(isStreaming: false),
    ];

    emit(state.copyWith(status: ChatStatus.ready, messages: updatedMessages));
  }

  void _onClearChat(ClearChat event, Emitter<ChatState> emit) {
    _inferenceSubscription?.cancel();
    _inferenceService.resetSession();
    emit(const ChatState(status: ChatStatus.ready));
  }

  void _onChatError(ChatError event, Emitter<ChatState> emit) {
    _inferenceSubscription?.cancel();

    // Mark the last streaming message as done (with whatever text it has)
    final messages = state.messages;
    final updatedMessages = messages.map((m) {
      return m.isStreaming ? m.copyWith(isStreaming: false) : m;
    }).toList();

    emit(
      state.copyWith(
        status: ChatStatus.error,
        messages: updatedMessages,
        errorMessage: event.errorMessage,
      ),
    );
  }

  @override
  Future<void> close() {
    _inferenceSubscription?.cancel();
    return super.close();
  }
}
