import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slm_app/core/channels/inference_service.dart';
import 'package:slm_app/core/channels/mock_inference_service.dart';
import 'package:slm_app/core/channels/mock_embedding_service.dart';
import 'package:slm_app/features/chat/bloc/chat_bloc.dart';
import 'package:slm_app/features/chat/bloc/chat_event.dart';
import 'package:slm_app/features/chat/bloc/chat_state.dart';
import 'package:slm_app/features/model_manager/loader/model_loader.dart';
import 'package:slm_app/features/rag/indexer/document_indexer.dart';
import 'package:slm_app/features/rag/retriever/context_builder.dart';
import 'package:slm_app/features/rag/retriever/rag_retriever.dart';
import 'package:slm_app/features/rag/vector_store/vector_store.dart';

class FakeModelLoader implements ModelLoader {
  bool _isLoaded = false;
  int ensureLoadCalls = 0;

  @override
  bool get isLoaded => _isLoaded;

  @override
  Future<void> ensureModelLoaded({
    void Function(double progress)? onDownloadProgress,
  }) async {
    ensureLoadCalls += 1;
    _isLoaded = true;
  }

  @override
  Future<void> unloadModel() async {
    _isLoaded = false;
  }

  @override
  Future<List<String>> checkCompatibility() async => [];

  @override
  Future<bool> deleteModel() async => true;

  @override
  Future<String> downloadModel({
    void Function(double progress)? onProgress,
  }) async => 'mock_path';

  @override
  Future<bool> isModelDownloaded() async => true;
}

class ControlledInferenceService implements InferenceService {
  final StreamController<String> _controller = StreamController<String>();
  bool cancelCalled = false;

  @override
  Future<void> loadModel(String modelPath) async {}

  @override
  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 1024,
    double temperature = 0.7,
  }) {
    return _controller.stream;
  }

  @override
  Future<void> cancelGeneration() async {
    cancelCalled = true;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  @override
  Future<void> resetSession() async {}

  @override
  Future<void> dispose() async {
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  @override
  Future<ModelInfo> getModelInfo() async {
    return const ModelInfo(
      name: 'Controlled Test Model',
      sizeBytes: 1,
      contextLength: 8192,
    );
  }

  void emitToken(String token) {
    if (!_controller.isClosed) {
      _controller.add(token);
    }
  }
}

void main() {
  group('ChatBloc and RAG Integration Tests', () {
    late MockInferenceService mockInferenceService;
    late FakeModelLoader fakeModelLoader;
    late MockEmbeddingService mockEmbeddingService;
    late VectorStore vectorStore;
    late DocumentIndexer documentIndexer;
    late RagRetriever ragRetriever;
    late ContextBuilder contextBuilder;
    late ChatBloc chatBloc;

    setUp(() {
      mockInferenceService = MockInferenceService();
      fakeModelLoader = FakeModelLoader();
      mockEmbeddingService = MockEmbeddingService();
      vectorStore = VectorStore();
      documentIndexer = DocumentIndexer(
        embedder: mockEmbeddingService,
        vectorStore: vectorStore,
      );
      ragRetriever = RagRetriever(
        embedder: mockEmbeddingService,
        store: vectorStore,
      );
      contextBuilder = const ContextBuilder();
      chatBloc = ChatBloc(
        inferenceService: mockInferenceService,
        modelLoader: fakeModelLoader,
        documentIndexer: documentIndexer,
        ragRetriever: ragRetriever,
        contextBuilder: contextBuilder,
      );
    });

    tearDown(() {
      chatBloc.close();
    });

    test('Initial state has RAG disabled and zero documents', () {
      expect(chatBloc.state.useRag, isFalse);
      expect(chatBloc.state.documentCount, 0);
    });

    test('ToggleRag event updates state.useRag', () {
      expect(chatBloc.state.useRag, isFalse);
      chatBloc.add(const ToggleRag());
      expect(
        chatBloc.stream,
        emitsThrough(predicate((ChatState state) => state.useRag == true)),
      );
    });

    test('IndexDocument event updates document count', () async {
      chatBloc.add(
        const IndexDocument(
          title: 'Test Doc',
          content: 'This is a document about Flutter offline AI chat.',
        ),
      );

      await expectLater(
        chatBloc.stream,
        emitsThrough(predicate((ChatState state) => state.documentCount == 1)),
      );

      final docs = await vectorStore.listDocuments();
      expect(docs.length, 1);
      expect(docs.first.title, 'Test Doc');
    });

    test(
      'PreloadModel loads the model without sending a chat message',
      () async {
        chatBloc.add(const PreloadModel());

        await expectLater(
          chatBloc.stream,
          emitsThrough(
            predicate<ChatState>(
              (state) =>
                  state.status == ChatStatus.ready &&
                  state.isModelLoaded &&
                  state.messages.isEmpty,
            ),
          ),
        );

        expect(fakeModelLoader.ensureLoadCalls, 1);
      },
    );

    test(
      'CancelGeneration stops streaming and preserves partial assistant text',
      () async {
        final controlledInferenceService = ControlledInferenceService();
        final cancelBloc = ChatBloc(
          inferenceService: controlledInferenceService,
          modelLoader: fakeModelLoader,
          documentIndexer: documentIndexer,
          ragRetriever: ragRetriever,
          contextBuilder: contextBuilder,
        );

        addTearDown(cancelBloc.close);

        cancelBloc.add(const SendMessage('Explain offline inference'));

        await expectLater(
          cancelBloc.stream,
          emitsThrough(
            predicate<ChatState>(
              (state) =>
                  state.status == ChatStatus.generating &&
                  state.messages.length == 2 &&
                  state.messages.last.isStreaming,
            ),
          ),
        );

        controlledInferenceService.emitToken('Partial answer');

        await expectLater(
          cancelBloc.stream,
          emitsThrough(
            predicate<ChatState>(
              (state) => state.messages.last.text == 'Partial answer',
            ),
          ),
        );

        cancelBloc.add(const CancelGeneration());

        await expectLater(
          cancelBloc.stream,
          emitsThrough(
            predicate<ChatState>(
              (state) =>
                  state.status == ChatStatus.ready &&
                  state.messages.last.text == 'Partial answer' &&
                  !state.messages.last.isStreaming,
            ),
          ),
        );

        expect(controlledInferenceService.cancelCalled, isTrue);
      },
    );
  });
}
