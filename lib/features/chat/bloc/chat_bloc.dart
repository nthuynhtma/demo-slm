import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../../../core/channels/inference_service.dart';
import '../../model_manager/loader/model_loader.dart';
import '../../rag/indexer/document_indexer.dart';
import '../../rag/retriever/context_builder.dart';
import '../../rag/retriever/rag_retriever.dart';

import '../models/chat_message.dart';
import 'chat_event.dart';
import 'chat_state.dart';

/// Business logic component for the chat feature.
///
/// Manages the conversation state, handles model inference via
/// [InferenceService], processes streaming token updates, orchestrates model downloads,
/// and integrates the RAG pipeline.
class ChatBloc extends Bloc<ChatEvent, ChatState> {
  final InferenceService _inferenceService;
  final ModelLoader _modelLoader;
  final DocumentIndexer? _documentIndexer;
  final RagRetriever? _ragRetriever;
  final ContextBuilder? _contextBuilder;
  final Uuid _uuid = const Uuid();
  StreamSubscription<String>? _inferenceSubscription;
  static const String _systemPrompt =
      'You are a helpful offline AI assistant running on-device. '
      'Answer clearly and use the provided conversation history when relevant.';

  ChatBloc({
    required InferenceService inferenceService,
    required ModelLoader modelLoader,
    DocumentIndexer? documentIndexer,
    RagRetriever? ragRetriever,
    ContextBuilder? contextBuilder,
  })  : _inferenceService = inferenceService,
        _modelLoader = modelLoader,
        _documentIndexer = documentIndexer,
        _ragRetriever = ragRetriever,
        _contextBuilder = contextBuilder,
        super(const ChatState()) {
    on<SendMessage>(_onSendMessage);
    on<StreamToken>(_onStreamToken);
    on<StreamComplete>(_onStreamComplete);
    on<ClearChat>(_onClearChat);
    on<ChatError>(_onChatError);
    on<ToggleRag>(_onToggleRag);
    on<DownloadModel>(_onDownloadModel);
    on<DownloadProgressUpdate>(_onDownloadProgressUpdate);
    on<DeleteModel>(_onDeleteModel);
    on<RefreshModelStatus>(_onRefreshModelStatus);
    on<IndexDocument>(_onIndexDocument);
    on<ClearIndex>(_onClearIndex);

    // Initial check of model and RAG status
    add(const RefreshModelStatus());
  }

  Future<void> _onSendMessage(
    SendMessage event,
    Emitter<ChatState> emit,
  ) async {
    final queryText = event.message.trim();
    if (queryText.isEmpty) return;

    // Add user message
    final userMessage = ChatMessage(
      id: _uuid.v4(),
      text: queryText,
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
      // Step 1: Ensure the model is loaded (and downloaded if necessary)
      await _modelLoader.ensureModelLoaded();
      
      // Update state to downloaded & loaded
      final isDownloaded = await _modelLoader.isModelDownloaded();
      emit(state.copyWith(
        status: ChatStatus.generating,
        isModelDownloaded: isDownloaded,
        isModelLoaded: true,
        clearError: true,
      ));

      // Step 2: Retrieve context from RAG if enabled
      final queryToSend = state.useRag
          ? await _buildRagPrompt(queryText)
          : queryText;

      final promptMessagesForGeneration = [
        ...state.messages,
        userMessage.copyWith(text: queryToSend),
      ];

      final prompt = _buildPrompt(promptMessagesForGeneration);

      // Step 3: Subscribe to streaming inference
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

  /// Retrieve context chunks and build an augmented prompt.
  Future<String> _buildRagPrompt(String userMessage) async {
    final retriever = _ragRetriever;
    final builder = _contextBuilder;
    if (retriever == null || builder == null) return userMessage;

    try {
      final results = await retriever.retrieve(userMessage, topK: 3);
      if (results.isEmpty) return userMessage;
      return builder.build(results, userMessage);
    } catch (_) {
      return userMessage; // Fallback to original query on failure
    }
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
    emit(state.copyWith(
      status: ChatStatus.ready,
      messages: const [],
      clearError: true,
    ));
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

  void _onToggleRag(ToggleRag event, Emitter<ChatState> emit) {
    emit(state.copyWith(useRag: !state.useRag));
  }

  Future<void> _onDownloadModel(DownloadModel event, Emitter<ChatState> emit) async {
    if (state.isDownloading) return;
    emit(state.copyWith(
      isDownloading: true,
      downloadProgress: 0.0,
      clearError: true,
    ));

    try {
      await _modelLoader.downloadModel(
        onProgress: (progress) {
          add(DownloadProgressUpdate(progress));
        },
      );

      final isDownloaded = await _modelLoader.isModelDownloaded();
      emit(state.copyWith(
        isDownloading: false,
        downloadProgress: 1.0,
        isModelDownloaded: isDownloaded,
      ));
    } catch (e) {
      emit(state.copyWith(
        isDownloading: false,
        errorMessage: e.toString(),
        status: ChatStatus.error,
      ));
    }
  }

  void _onDownloadProgressUpdate(DownloadProgressUpdate event, Emitter<ChatState> emit) {
    emit(state.copyWith(downloadProgress: event.progress));
  }

  Future<void> _onDeleteModel(DeleteModel event, Emitter<ChatState> emit) async {
    try {
      await _modelLoader.deleteModel();
      emit(state.copyWith(
        isModelDownloaded: false,
        isModelLoaded: false,
        downloadProgress: 0.0,
      ));
    } catch (e) {
      emit(state.copyWith(
        errorMessage: e.toString(),
        status: ChatStatus.error,
      ));
    }
  }

  Future<void> _onRefreshModelStatus(RefreshModelStatus event, Emitter<ChatState> emit) async {
    final isDownloaded = await _modelLoader.isModelDownloaded();
    final isLoaded = _modelLoader.isLoaded;
    final docCount = _documentIndexer != null
        ? await _documentIndexer!.documentCount
        : 0;

    emit(state.copyWith(
      isModelDownloaded: isDownloaded,
      isModelLoaded: isLoaded,
      documentCount: docCount,
    ));
  }

  Future<void> _onIndexDocument(IndexDocument event, Emitter<ChatState> emit) async {
    final indexer = _documentIndexer;
    if (indexer == null) return;

    emit(state.copyWith(
      indexingProgress: 0.0,
      clearError: true,
    ));

    try {
      await for (final progress in indexer.indexText(
        event.content,
        title: event.title,
      )) {
        emit(state.copyWith(indexingProgress: progress.fraction));
      }

      final docCount = await indexer.documentCount;
      emit(state.copyWith(
        documentCount: docCount,
        clearIndexingProgress: true,
      ));
    } catch (e) {
      emit(state.copyWith(
        clearIndexingProgress: true,
        errorMessage: e.toString(),
        status: ChatStatus.error,
      ));
    }
  }

  Future<void> _onClearIndex(ClearIndex event, Emitter<ChatState> emit) async {
    final indexer = _documentIndexer;
    if (indexer == null) return;

    try {
      await indexer.clearIndex();
      emit(state.copyWith(documentCount: 0));
    } catch (e) {
      emit(state.copyWith(
        errorMessage: e.toString(),
        status: ChatStatus.error,
      ));
    }
  }

  @override
  Future<void> close() async {
    await _inferenceSubscription?.cancel();
    await _modelLoader.unloadModel();
    return super.close();
  }
}
