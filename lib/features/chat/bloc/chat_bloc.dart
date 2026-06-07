import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';
import '../../../core/channels/inference_service.dart';
import '../../model_manager/loader/model_loader.dart';
import '../../model_manager/download/model_downloader.dart';
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
  StreamSubscription<ModelDownloadUpdate>? _downloadSubscription;
  final StringBuffer _tokenBuffer = StringBuffer();
  Timer? _flushTimer;
  int _feedbackVersion = 0;
  static const String _systemPrompt =
      'You are a helpful offline AI assistant running on-device. '
      'Answer clearly and use the provided context and conversation history when relevant.';

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
    on<PauseModelDownload>(_onPauseModelDownload);
    on<ResumeModelDownload>(_onResumeModelDownload);
    on<CancelModelDownload>(_onCancelModelDownload);
    on<DownloadUpdateReceived>(_onDownloadUpdateReceived);

    // Subscribe to model download updates
    _downloadSubscription = _modelLoader.downloadUpdates.listen((update) {
      add(DownloadUpdateReceived(
        progress: update.progress,
        status: update.status,
        errorMessage: update.errorMessage,
      ));
    });

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
      await _modelLoader.ensureModelLoaded().timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          throw TimeoutException('Model loading timed out during message sending.');
        },
      );

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
          ? await _ragRetriever.retrieve(queryText, topK: 3)
          : [];

      final retrievedContextText = results.isNotEmpty && _contextBuilder != null
          ? _contextBuilder.build(results, queryText)
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
    if (state.status == ChatStatus.generating) {
      return;
    }

    if (_modelLoader.isLoaded) {
      _logAction('Model already loaded.');
      emit(_withFeedback(
        state.copyWith(status: ChatStatus.ready, isModelLoaded: true),
        'Model is already loaded.',
      ));
      return;
    }

    _logAction('Loading model into memory...');
    emit(_withFeedback(
      state.copyWith(status: ChatStatus.loadingModel, clearError: true),
      'Loading model into memory...',
    ));

    try {
      // ignore: avoid_print
      print('[ChatBloc] Starting model preload with 90s timeout...');
      
      // Add a timeout to prevent hanging UI if native engine fails to respond
      await _modelLoader.ensureModelLoaded().timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          throw TimeoutException('Model loading timed out after 90 seconds. The model might be too large for this device or the engine is stuck.');
        },
      );
      
      final isDownloaded = await _modelLoader.isModelDownloaded();
      
      _logAction('Model preload successful.');
      emit(_withFeedback(
        state.copyWith(
          status: ChatStatus.ready,
          isModelDownloaded: isDownloaded,
          isModelLoaded: true,
          clearError: true,
        ),
        'Model loaded and ready for chat.',
      ));
    } catch (e) {
      _logAction('Model preload failed: $e');
      emit(_withFeedback(
        state.copyWith(
          status: ChatStatus.error,
          errorMessage: 'Failed to load model into memory: $e',
          isModelLoaded: false,
        ),
        'Failed to load model into memory.',
        isError: true,
      ));
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

  void _onStreamToken(StreamToken event, Emitter<ChatState> emit) {
    _tokenBuffer.write(event.token);

    _flushTimer ??= Timer.periodic(const Duration(milliseconds: 100), (timer) {
      // Use add() to dispatch through the Bloc event loop so that
      // emit() is always called with a valid Emitter context.
      // The Bloc event loop handles isClosed checks internally.
      add(const FlushTokens());
    });
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
    _logAction('Chat history cleared.');
    emit(_withFeedback(
      state.copyWith(
        status: ChatStatus.ready,
        messages: const [],
        clearError: true,
      ),
      'Chat history cleared.',
    ));
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
    final nextUseRag = !state.useRag;
    _logAction('RAG toggled ${nextUseRag ? 'on' : 'off'}.');
    emit(_withFeedback(
      state.copyWith(useRag: nextUseRag),
      nextUseRag ? 'RAG enabled.' : 'RAG disabled.',
    ));
  }

  Future<bool> _ensureNotificationPermission(Emitter<ChatState> emit) async {
    final status = await Permission.notification.status;
    if (status.isGranted) return true;

    final result = await Permission.notification.request();
    if (result.isGranted) return true;

    if (result.isPermanentlyDenied) {
      emit(_withFeedback(
        state.copyWith(
          isDownloading: false,
          isDownloadPaused: false,
          errorMessage: 'Ứng dụng cần quyền thông báo để hiển thị tiến trình download.',
          status: ChatStatus.error,
        ),
        'Notification permission đã bị chặn. Vui lòng bật trong Cài đặt.',
        isError: true,
      ));
    } else {
      emit(_withFeedback(
        state.copyWith(
          isDownloading: false,
          isDownloadPaused: false,
          errorMessage: 'Ứng dụng cần quyền thông báo để hiển thị tiến trình download.',
          status: ChatStatus.error,
        ),
        'Quyền thông báo bị từ chối. Không thể hiển thị tiến trình download ngoài notification.',
        isError: true,
      ));
    }
    return false;
  }

  Future<void> _onDownloadModel(
    DownloadModel event,
    Emitter<ChatState> emit,
  ) async {
    if (state.isDownloading && !state.isDownloadPaused) return;
    _logAction('Starting model download.');
    emit(_withFeedback(
      state.copyWith(
        isDownloading: true,
        isDownloadPaused: false,
        downloadProgress: 0.0,
        clearError: true,
      ),
      'Starting model download...',
    ));

    try {
      final granted = await _ensureNotificationPermission(emit);
      if (!granted) return;

      await _modelLoader.downloadModel();
    } catch (e) {
      _logAction('Download start failed: $e');
      emit(_withFeedback(
        state.copyWith(
          isDownloading: false,
          isDownloadPaused: false,
          errorMessage: e.toString(),
          status: ChatStatus.error,
        ),
        'Failed to start model download.',
        isError: true,
      ));
    }
  }

  void _onDownloadUpdateReceived(
    DownloadUpdateReceived event,
    Emitter<ChatState> emit,
  ) {
    final status = event.status;
    final progress = event.progress;

    switch (status) {
      case ModelDownloadStatus.enqueued:
        emit(state.copyWith(
          isDownloading: true,
          isDownloadPaused: false,
          downloadProgress: progress,
        ));
        break;
      case ModelDownloadStatus.downloading:
        emit(state.copyWith(
          isDownloading: true,
          isDownloadPaused: false,
          downloadProgress: progress,
        ));
        break;
      case ModelDownloadStatus.paused:
        emit(state.copyWith(
          isDownloading: true,
          isDownloadPaused: true,
          downloadProgress: progress,
        ));
        break;
      case ModelDownloadStatus.complete:
        _logAction('Download complete. Triggering preload.');
        emit(_withFeedback(state.copyWith(
          isDownloading: false,
          isDownloadPaused: false,
          downloadProgress: 1.0,
          isModelDownloaded: true,
          status: ChatStatus.loadingModel,
        ), 'Model download completed. Loading into memory...'));
        add(const PreloadModel());
        break;
      case ModelDownloadStatus.failed:
        _logAction('Download failed: ${event.errorMessage}');
        emit(_withFeedback(state.copyWith(
          isDownloading: false,
          isDownloadPaused: false,
          status: ChatStatus.error,
          errorMessage: event.errorMessage ?? 'Download failed',
        ), 'Model download failed.', isError: true));
        break;
      case ModelDownloadStatus.canceled:
        _logAction('Download canceled.');
        emit(_withFeedback(state.copyWith(
          isDownloading: false,
          isDownloadPaused: false,
          downloadProgress: 0.0,
          status: ChatStatus.needsDownload,
        ), 'Model download canceled.'));
        break;
      default:
        break;
    }
  }

  Future<void> _onPauseModelDownload(
    PauseModelDownload event,
    Emitter<ChatState> emit,
  ) async {
    try {
      _logAction('Pausing model download.');
      await _modelLoader.pauseDownload();
      emit(_withFeedback(state, 'Pausing model download...'));
    } catch (e) {
      _logAction('Pause download failed: $e');
      emit(_withFeedback(state.copyWith(errorMessage: e.toString()), 'Failed to pause model download.', isError: true));
    }
  }

  Future<void> _onResumeModelDownload(
    ResumeModelDownload event,
    Emitter<ChatState> emit,
  ) async {
    try {
      _logAction('Resuming model download.');
      await _modelLoader.resumeDownload();
      emit(_withFeedback(state, 'Resuming model download...'));
    } catch (e) {
      _logAction('Resume download failed: $e');
      emit(_withFeedback(state.copyWith(errorMessage: e.toString()), 'Failed to resume model download.', isError: true));
    }
  }

  Future<void> _onCancelModelDownload(
    CancelModelDownload event,
    Emitter<ChatState> emit,
  ) async {
    try {
      _logAction('Canceling model download.');
      await _modelLoader.cancelDownload();
      emit(_withFeedback(state, 'Canceling model download...'));
    } catch (e) {
      _logAction('Cancel download failed: $e');
      emit(_withFeedback(state.copyWith(errorMessage: e.toString()), 'Failed to cancel model download.', isError: true));
    }
  }

  /// Cancel the active generation while preserving any partial assistant text.
  Future<void> _onCancelGeneration(
    CancelGeneration event,
    Emitter<ChatState> emit,
  ) async {
    if (state.status != ChatStatus.generating) return;
    _logAction('Stopping response generation.');

    _flushTimer?.cancel();
    _flushTimer = null;

    final remainingText = _tokenBuffer.toString();
    _tokenBuffer.clear();

    await _inferenceSubscription?.cancel();
    _inferenceSubscription = null;
    await _inferenceService.cancelGeneration();

    emit(_withFeedback(
      state.copyWith(
        status: ChatStatus.ready,
        messages: _finalizeStreamingMessagesWithText(state.messages, remainingText),
        clearError: true,
      ),
      'Generation stopped.',
    ));
  }

  void _onDownloadProgressUpdate(
    DownloadProgressUpdate event,
    Emitter<ChatState> emit,
  ) {
    // Deprecated: updates are handled via DownloadUpdateReceived
  }

  Future<void> _onDeleteModel(
    DeleteModel event,
    Emitter<ChatState> emit,
  ) async {
    try {
      await _modelLoader.deleteModel();
      _logAction('Local model file deleted.');
      emit(_withFeedback(
        state.copyWith(
          isModelDownloaded: false,
          isModelLoaded: false,
          downloadProgress: 0.0,
          status: ChatStatus.needsDownload,
        ),
        'Local model file deleted.',
      ));
    } catch (e) {
      _logAction('Delete model failed: $e');
      emit(_withFeedback(
        state.copyWith(errorMessage: e.toString(), status: ChatStatus.error),
        'Failed to delete local model file.',
        isError: true,
      ));
    }
  }

  Future<void> _onRefreshModelStatus(
    RefreshModelStatus event,
    Emitter<ChatState> emit,
  ) async {
    final isDownloaded = await _modelLoader.isModelDownloaded();
    final isLoaded = _modelLoader.isLoaded;
    final docCount = _documentIndexer != null
        ? await _documentIndexer.documentCount
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

    _logAction('Indexing document: ${event.title}');
    emit(_withFeedback(
      state.copyWith(indexingProgress: 0.0, clearError: true),
      'Indexing "${event.title}"...',
    ));

    try {
      await for (final progress in indexer.indexText(
        event.content,
        title: event.title,
      )) {
        if (isClosed) return;
        emit(state.copyWith(indexingProgress: progress.fraction));
      }

      if (isClosed) return;
      final docCount = await indexer.documentCount;
      _logAction('Document indexed successfully: ${event.title}');
      emit(_withFeedback(
        state.copyWith(documentCount: docCount, clearIndexingProgress: true),
        'Document indexed successfully.',
      ));
    } catch (e) {
      _logAction('Index document failed: $e');
      emit(_withFeedback(
        state.copyWith(
          clearIndexingProgress: true,
          errorMessage: e.toString(),
          status: ChatStatus.error,
        ),
        'Failed to index document.',
        isError: true,
      ));
    }
  }

  Future<void> _onClearIndex(ClearIndex event, Emitter<ChatState> emit) async {
    final indexer = _documentIndexer;
    if (indexer == null) return;

    try {
      await indexer.clearIndex();
      _logAction('Knowledge base cleared.');
      emit(_withFeedback(state.copyWith(documentCount: 0), 'Knowledge base cleared.'));
    } catch (e) {
      _logAction('Clear knowledge base failed: $e');
      emit(_withFeedback(
        state.copyWith(errorMessage: e.toString(), status: ChatStatus.error),
        'Failed to clear knowledge base.',
        isError: true,
      ));
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
        await _ragRetriever.store.loadFromDisk();
      }

      // 2. Parallel check of model downloaded and document count
      final results = await Future.wait([
        _modelLoader.isModelDownloaded(),
        _documentIndexer != null ? _documentIndexer.documentCount : Future<int>.value(0),
      ]);
      final isDownloaded = results[0] as bool;
      final docCount = results[1] as int;

      // Check if there is an active background download running or paused
      final activeDownload = await _modelLoader.getActiveDownloadUpdate();
      final isDownloading = activeDownload.status == ModelDownloadStatus.downloading ||
                            activeDownload.status == ModelDownloadStatus.enqueued ||
                            activeDownload.status == ModelDownloadStatus.paused;
      final isPaused = activeDownload.status == ModelDownloadStatus.paused;

      emit(_withFeedback(
        state.copyWith(
          isModelDownloaded: isDownloaded,
          documentCount: docCount,
          isDownloading: isDownloading,
          isDownloadPaused: isPaused,
          downloadProgress: activeDownload.progress,
        ),
        isDownloading
            ? (isPaused ? 'Model download is paused.' : 'Model download is in progress.')
            : (isDownloaded ? 'Downloaded model found on device.' : 'No local model found.'),
      ));

      // 3. Branch based on whether model is downloaded
      if (isDownloaded) {
        _logAction('Model found on disk at startup. Auto-preloading.');
        emit(_withFeedback(
          state.copyWith(status: ChatStatus.loadingModel),
          'Found downloaded model. Loading into memory...',
        ));
        
        await _modelLoader.ensureModelLoaded().timeout(
          const Duration(seconds: 90),
          onTimeout: () {
            throw TimeoutException('Startup model loading timed out after 90 seconds.');
          },
        );
        
        _logAction('Startup auto-preload successful.');
        emit(_withFeedback(
          state.copyWith(
            status: ChatStatus.ready,
            isModelLoaded: true,
            clearError: true,
          ),
          'Model loaded automatically and ready.',
        ));
      } else {
        _logAction('Model not found on disk at startup.');
        emit(_withFeedback(
          state.copyWith(status: ChatStatus.needsDownload),
          'No local model found. Please download the model first.',
        ));
      }
    } catch (e) {
      _logAction('Startup initialization failed: $e');
      emit(_withFeedback(
        state.copyWith(
          status: ChatStatus.error,
          errorMessage: 'Startup initialization failed: $e',
        ),
        'Startup initialization failed.',
        isError: true,
      ));
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
    await _downloadSubscription?.cancel();
    await _inferenceSubscription?.cancel();
    await _modelLoader.unloadModel();
    return super.close();
  }

  void _logAction(String message) {
    // ignore: avoid_print
    print('[ChatBloc] $message');
  }

  ChatState _withFeedback(
    ChatState current,
    String message, {
    bool isError = false,
  }) {
    return current.copyWith(
      feedbackMessage: message,
      feedbackIsError: isError,
      feedbackVersion: ++_feedbackVersion,
    );
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
