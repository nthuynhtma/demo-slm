import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../../../core/channels/inference_service.dart';
import '../../model_manager/loader/model_loader.dart';
import '../../rag/indexer/document_indexer.dart';
import '../../rag/retriever/context_builder.dart';
import '../../rag/retriever/rag_retriever.dart';
import '../../rag/vector_store/vector_store.dart';
import 'token_budget_allocator.dart';

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
  final StringBuffer _tokenBuffer = StringBuffer();
  Timer? _flushTimer;
  static const String _systemPrompt =
      'You are a helpful offline AI assistant running on-device. '
      'Answer clearly and use the provided conversation history when relevant.';

  ChatBloc({
    required InferenceService inferenceService,
    required ModelLoader modelLoader,
    DocumentIndexer? documentIndexer,
    RagRetriever? ragRetriever,
    ContextBuilder? contextBuilder,
  }) : _inferenceService = inferenceService,
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
    on<PreloadModel>(_onPreloadModel);
    on<DownloadProgressUpdate>(_onDownloadProgressUpdate);
    on<DeleteModel>(_onDeleteModel);
    on<CancelGeneration>(_onCancelGeneration);
    on<RefreshModelStatus>(_onRefreshModelStatus);
    on<IndexDocument>(_onIndexDocument);
    on<ClearIndex>(_onClearIndex);
    on<StartupRequested>(_onStartupRequested);
    on<AppBackgrounded>(_onAppBackgrounded);
    on<AppForegrounded>(_onAppForegrounded);
    on<FlushTokens>(_onFlushTokens);

    // Initial check of model and RAG status
    add(const StartupRequested());
  }

  Future<void> _onSendMessage(
    SendMessage event,
    Emitter<ChatState> emit,
  ) async {
    if (state.status == ChatStatus.generating ||
        state.status == ChatStatus.loadingModel) {
      return;
    }

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
      // Step 1: Ensure the model is loaded
      await _modelLoader.ensureModelLoaded();

      // Update state to downloaded & loaded
      final isDownloaded = await _modelLoader.isModelDownloaded();
      emit(
        state.copyWith(
          status: ChatStatus.generating,
          isModelDownloaded: isDownloaded,
          isModelLoaded: true,
          clearError: true,
        ),
      );

      // Step 2: Retrieve context from RAG if enabled
      final List<SearchResult> results = state.useRag && _ragRetriever != null
          ? await _ragRetriever!.retrieve(queryText, topK: 3)
          : [];

      final retrievedContextText = results.isNotEmpty && _contextBuilder != null
          ? _contextBuilder!.build(results, queryText)
          : null;

      // Step 3: Allocate token budgets
      // NOTE: currentQuery is always the original queryText to avoid
      // double-counting the RAG context tokens (the allocator already
      // accounts for ragContextCost separately).
      final history = state.messages.length > 2
          ? state.messages.sublist(0, state.messages.length - 2)
          : <ChatMessage>[];

      const budgetAllocator = TokenBudgetAllocator();
      final budgetedHistory = budgetAllocator.allocate(
        history: history,
        systemPrompt: _systemPrompt,
        retrievedContext: retrievedContextText,
        currentQuery: queryText, // ← always original query, not RAG-concatenated
      );

      // Build the prompt with RAG context prepended to user message
      // (the model receives the retrieved context as part of the user turn)
      final queryForPrompt = retrievedContextText ?? queryText;
      final promptMessagesForGeneration = [
        ...budgetedHistory,
        userMessage.copyWith(text: queryForPrompt),
      ];

      final prompt = _buildPromptFromMessages(promptMessagesForGeneration);

      // Step 4: Subscribe to streaming inference
      _tokenBuffer.clear();
      _flushTimer?.cancel();
      _flushTimer = null;

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

  /// Load the downloaded model into memory without sending a chat message.
  Future<void> _onPreloadModel(
    PreloadModel event,
    Emitter<ChatState> emit,
  ) async {
    if (state.status == ChatStatus.generating ||
        state.status == ChatStatus.loadingModel) {
      return;
    }

    emit(state.copyWith(status: ChatStatus.loadingModel, clearError: true));

    try {
      await _modelLoader.ensureModelLoaded();
      final isDownloaded = await _modelLoader.isModelDownloaded();
      emit(
        state.copyWith(
          status: ChatStatus.ready,
          isModelDownloaded: isDownloaded,
          isModelLoaded: true,
          clearError: true,
        ),
      );
    } catch (e) {
      emit(
        state.copyWith(
          status: ChatStatus.error,
          errorMessage: e.toString(),
          isModelLoaded: false,
        ),
      );
    }
  }

  /// Build a Gemma chat prompt from a custom list of messages (already budgeted).
  String _buildPromptFromMessages(List<ChatMessage> history) {
    final buf = StringBuffer();
    buf.write('<start_of_turn>system\n$_systemPrompt<end_of_turn>\n');

    for (final message in history) {
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

  void _onStreamToken(StreamToken event, Emitter<ChatState> emit) {
    _tokenBuffer.write(event.token);

    if (_flushTimer == null) {
      _flushTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
        // Use add() to dispatch through the Bloc event loop so that
        // emit() is always called with a valid Emitter context.
        // The Bloc event loop handles isClosed checks internally.
        add(const FlushTokens());
      });
    }
  }

  void _onFlushTokens(FlushTokens event, Emitter<ChatState> emit) {
    final textToFlush = _tokenBuffer.toString();
    if (textToFlush.isEmpty) return;
    _tokenBuffer.clear();

    final messages = state.messages;
    if (messages.isEmpty) return;

    final lastMessage = messages.last;
    if (!lastMessage.isStreaming) return;

    final updatedMessages = [
      ...messages.sublist(0, messages.length - 1),
      lastMessage.copyWith(text: lastMessage.text + textToFlush),
    ];

    // Guard against emit after close — if the Bloc was closed between
    // the timer firing and this handler running, emit() would throw.
    if (!isClosed) {
      emit(state.copyWith(messages: updatedMessages));
    }
  }

  void _onStreamComplete(StreamComplete event, Emitter<ChatState> emit) {
    _flushTimer?.cancel();
    _flushTimer = null;

    final remainingText = _tokenBuffer.toString();
    _tokenBuffer.clear();

    _inferenceSubscription = null;
    final messages = state.messages;
    if (messages.isEmpty) return;

    final lastMessage = messages.last;
    if (!lastMessage.isStreaming) return;

    final updatedMessages = [
      ...messages.sublist(0, messages.length - 1),
      lastMessage.copyWith(
        text: lastMessage.text + remainingText,
        isStreaming: false,
      ),
    ];

    emit(state.copyWith(status: ChatStatus.ready, messages: updatedMessages));
  }

  Future<void> _onClearChat(ClearChat event, Emitter<ChatState> emit) async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _tokenBuffer.clear();

    await _inferenceSubscription?.cancel();
    _inferenceSubscription = null;
    await _inferenceService.resetSession();
    emit(
      state.copyWith(
        status: ChatStatus.ready,
        messages: const [],
        clearError: true,
      ),
    );
  }

  void _onChatError(ChatError event, Emitter<ChatState> emit) {
    _flushTimer?.cancel();
    _flushTimer = null;

    final remainingText = _tokenBuffer.toString();
    _tokenBuffer.clear();

    _inferenceSubscription?.cancel();
    _inferenceSubscription = null;

    // Mark the last streaming message as done (with whatever text it has)
    final messages = state.messages;
    final updatedMessages = messages.map((m) {
      if (m.isStreaming) {
        return m.copyWith(
          text: m.text + remainingText,
          isStreaming: false,
        );
      }
      return m;
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

  Future<void> _onDownloadModel(
    DownloadModel event,
    Emitter<ChatState> emit,
  ) async {
    if (state.isDownloading) return;
    emit(
      state.copyWith(
        isDownloading: true,
        downloadProgress: 0.0,
        clearError: true,
      ),
    );

    try {
      await _modelLoader.downloadModel(
        onProgress: (progress) {
          add(DownloadProgressUpdate(progress));
        },
      );

      final isDownloaded = await _modelLoader.isModelDownloaded();
      emit(
        state.copyWith(
          isDownloading: false,
          downloadProgress: 1.0,
          isModelDownloaded: isDownloaded,
          status: ChatStatus.loadingModel,
        ),
      );

      await _modelLoader.ensureModelLoaded();
      emit(
        state.copyWith(
          status: ChatStatus.ready,
          isModelLoaded: true,
          clearError: true,
        ),
      );
    } catch (e) {
      emit(
        state.copyWith(
          isDownloading: false,
          errorMessage: e.toString(),
          status: ChatStatus.error,
        ),
      );
    }
  }

  /// Cancel the active generation while preserving any partial assistant text.
  Future<void> _onCancelGeneration(
    CancelGeneration event,
    Emitter<ChatState> emit,
  ) async {
    if (state.status != ChatStatus.generating) return;

    _flushTimer?.cancel();
    _flushTimer = null;

    final remainingText = _tokenBuffer.toString();
    _tokenBuffer.clear();

    await _inferenceSubscription?.cancel();
    _inferenceSubscription = null;
    await _inferenceService.cancelGeneration();

    emit(
      state.copyWith(
        status: ChatStatus.ready,
        messages: _finalizeStreamingMessagesWithText(state.messages, remainingText),
        clearError: true,
      ),
    );
  }

  void _onDownloadProgressUpdate(
    DownloadProgressUpdate event,
    Emitter<ChatState> emit,
  ) {
    emit(state.copyWith(downloadProgress: event.progress));
  }

  Future<void> _onDeleteModel(
    DeleteModel event,
    Emitter<ChatState> emit,
  ) async {
    try {
      await _modelLoader.deleteModel();
      emit(
        state.copyWith(
          isModelDownloaded: false,
          isModelLoaded: false,
          downloadProgress: 0.0,
          status: ChatStatus.needsDownload,
        ),
      );
    } catch (e) {
      emit(
        state.copyWith(errorMessage: e.toString(), status: ChatStatus.error),
      );
    }
  }

  Future<void> _onRefreshModelStatus(
    RefreshModelStatus event,
    Emitter<ChatState> emit,
  ) async {
    final isDownloaded = await _modelLoader.isModelDownloaded();
    final isLoaded = _modelLoader.isLoaded;
    final docCount = _documentIndexer != null
        ? await _documentIndexer!.documentCount
        : 0;

    emit(
      state.copyWith(
        isModelDownloaded: isDownloaded,
        isModelLoaded: isLoaded,
        documentCount: docCount,
      ),
    );
  }

  Future<void> _onIndexDocument(
    IndexDocument event,
    Emitter<ChatState> emit,
  ) async {
    final indexer = _documentIndexer;
    if (indexer == null) return;

    emit(state.copyWith(indexingProgress: 0.0, clearError: true));

    try {
      await for (final progress in indexer.indexText(
        event.content,
        title: event.title,
      )) {
        emit(state.copyWith(indexingProgress: progress.fraction));
      }

      final docCount = await indexer.documentCount;
      emit(
        state.copyWith(documentCount: docCount, clearIndexingProgress: true),
      );
    } catch (e) {
      emit(
        state.copyWith(
          clearIndexingProgress: true,
          errorMessage: e.toString(),
          status: ChatStatus.error,
        ),
      );
    }
  }

  Future<void> _onClearIndex(ClearIndex event, Emitter<ChatState> emit) async {
    final indexer = _documentIndexer;
    if (indexer == null) return;

    try {
      await indexer.clearIndex();
      emit(state.copyWith(documentCount: 0));
    } catch (e) {
      emit(
        state.copyWith(errorMessage: e.toString(), status: ChatStatus.error),
      );
    }
  }

  Future<void> _onStartupRequested(
    StartupRequested event,
    Emitter<ChatState> emit,
  ) async {
    emit(state.copyWith(status: ChatStatus.checkingStartup));

    try {
      // 1. Load VectorStore from disk
      if (_ragRetriever != null) {
        await _ragRetriever!.store.loadFromDisk();
      }

      // 2. Parallel check of model downloaded and document count
      final results = await Future.wait([
        _modelLoader.isModelDownloaded(),
        _documentIndexer != null ? _documentIndexer!.documentCount : Future<int>.value(0),
      ]);
      final isDownloaded = results[0] as bool;
      final docCount = results[1] as int;

      emit(
        state.copyWith(
          isModelDownloaded: isDownloaded,
          documentCount: docCount,
        ),
      );

      // 3. Branch based on whether model is downloaded
      if (isDownloaded) {
        emit(state.copyWith(status: ChatStatus.loadingModel));
        await _modelLoader.ensureModelLoaded();
        emit(
          state.copyWith(
            status: ChatStatus.ready,
            isModelLoaded: true,
            clearError: true,
          ),
        );
      } else {
        emit(state.copyWith(status: ChatStatus.needsDownload));
      }
    } catch (e) {
      emit(
        state.copyWith(
          status: ChatStatus.error,
          errorMessage: 'Startup initialization failed: $e',
        ),
      );
    }
  }

  Future<void> _onAppBackgrounded(
    AppBackgrounded event,
    Emitter<ChatState> emit,
  ) async {
    // Cancel generation inline — await the cancellation fully before
    // unloading the model to avoid a race between the two operations.
    if (state.status == ChatStatus.generating) {
      _flushTimer?.cancel();
      _flushTimer = null;

      final remainingText = _tokenBuffer.toString();
      _tokenBuffer.clear();

      await _inferenceSubscription?.cancel();
      _inferenceSubscription = null;
      await _inferenceService.cancelGeneration();

      emit(
        state.copyWith(
          messages: _finalizeStreamingMessagesWithText(
            state.messages,
            remainingText,
          ),
          clearError: true,
        ),
      );
    }

    if (_modelLoader.isLoaded) {
      await _modelLoader.unloadModel();
      emit(
        state.copyWith(
          isModelLoaded: false,
          status: ChatStatus.ready,
        ),
      );
    }
  }

  Future<void> _onAppForegrounded(
    AppForegrounded event,
    Emitter<ChatState> emit,
  ) async {
    final isDownloaded = await _modelLoader.isModelDownloaded();
    if (isDownloaded && !_modelLoader.isLoaded && state.status != ChatStatus.loadingModel) {
      add(const PreloadModel());
    }
  }

  @override
  Future<void> close() async {
    _flushTimer?.cancel();
    await _inferenceSubscription?.cancel();
    await _modelLoader.unloadModel();
    return super.close();
  }

  List<ChatMessage> _finalizeStreamingMessagesWithText(List<ChatMessage> messages, String remainingText) {
    if (messages.isEmpty) return messages;

    final lastMessage = messages.last;
    if (!lastMessage.isStreaming) return messages;
    
    final newText = lastMessage.text + remainingText;
    if (newText.trim().isEmpty) {
      return messages.sublist(0, messages.length - 1);
    }

    return [
      ...messages.sublist(0, messages.length - 1),
      lastMessage.copyWith(text: newText, isStreaming: false),
    ];
  }
}
