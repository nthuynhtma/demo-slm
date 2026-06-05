import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../../../core/channels/inference_service.dart';
import '../../model_manager/loader/model_loader.dart';

import '../models/chat_message.dart';
import 'chat_event.dart';
import 'chat_state.dart';

/// Business logic component for the chat feature.
///
/// Manages the conversation state, handles model inference via
/// [InferenceService], and processes streaming token updates.
class ChatBloc extends Bloc<ChatEvent, ChatState> {
  final InferenceService _inferenceService;
  final ModelLoader _modelLoader;
  final Uuid _uuid = const Uuid();
  StreamSubscription<String>? _inferenceSubscription;
  static const String _systemPrompt =
      'You are a helpful offline AI assistant running on-device. '
      'Answer clearly and use the provided conversation history when relevant.';

  ChatBloc({
    required InferenceService inferenceService,
    required ModelLoader modelLoader,
  })
    : _inferenceService = inferenceService,
      _modelLoader = modelLoader,
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
    final promptMessages = [...state.messages, userMessage];
    final pendingMessages = [...state.messages, userMessage, assistantMessage];

    emit(
      state.copyWith(
        status: _modelLoader.isLoaded
            ? ChatStatus.generating
            : ChatStatus.loadingModel,
        messages: pendingMessages,
      ),
    );

    try {
      await _modelLoader.ensureModelLoaded();
      emit(state.copyWith(
        status: ChatStatus.generating,
        messages: pendingMessages,
        clearError: true,
      ));

      final prompt = _buildPrompt(promptMessages);

      // Subscribe to streaming inference
      await _inferenceSubscription?.cancel();
      final stream = _inferenceService.generateStream(prompt: prompt);
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

  /// Build a Gemma chat prompt from the current conversation history.
  String _buildPrompt(List<ChatMessage> history) {
    final trimmedHistory = _trimHistory(history);
    final buf = StringBuffer();
    buf.write('<start_of_turn>system\n$_systemPrompt<end_of_turn>\n');

    for (final message in trimmedHistory) {
      if (message.text.trim().isEmpty) continue;
      final role = switch (message.role) {
        MessageRole.user => 'user',
        MessageRole.assistant => 'model',
        MessageRole.system => 'system',
      };
      buf.write('<start_of_turn>$role\n${message.text}<end_of_turn>\n');
    }

    buf.write('<start_of_turn>model\n');
    return buf.toString();
  }

  /// Keep the newest messages that fit inside the target context budget.
  List<ChatMessage> _trimHistory(
    List<ChatMessage> history, {
    int maxTokens = 6000,
  }) {
    var totalTokens = 0;
    final trimmed = <ChatMessage>[];

    for (final message in history.reversed) {
      final estimatedTokens = (message.text.length / 3.5).ceil();
      if (totalTokens + estimatedTokens > maxTokens) break;
      totalTokens += estimatedTokens;
      trimmed.insert(0, message);
    }

    return trimmed;
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

  Future<void> _onClearChat(ClearChat event, Emitter<ChatState> emit) async {
    await _inferenceSubscription?.cancel();
    await _inferenceService.resetSession();
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
  Future<void> close() async {
    await _inferenceSubscription?.cancel();
    await _modelLoader.unloadModel();
    return super.close();
  }
}
