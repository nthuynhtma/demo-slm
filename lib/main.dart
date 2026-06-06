import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'core/channels/embedding_service.dart';
import 'core/channels/embedding_channel.dart';
import 'core/channels/inference_service.dart';
import 'core/channels/inference_channel.dart';
import 'core/channels/mock_embedding_service.dart';
import 'core/channels/mock_inference_service.dart';
import 'features/chat/bloc/chat_bloc.dart';
import 'features/chat/screens/chat_screen.dart';
import 'features/model_manager/download/model_downloader.dart';
import 'features/model_manager/loader/model_loader.dart';
import 'features/rag/indexer/document_indexer.dart';
import 'features/rag/retriever/context_builder.dart';
import 'features/rag/retriever/rag_retriever.dart';
import 'features/rag/vector_store/vector_store.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Use --dart-define=USE_MOCK=true to run with mock services
  // Use --dart-define=USE_MOCK=false (or omit) for real device with LiteRT-LM
  const bool useMock = bool.fromEnvironment('USE_MOCK', defaultValue: false);

  // ── Inference ──
  final InferenceService inferenceService = useMock
      ? MockInferenceService()
      : InferenceChannel();

  // ── RAG: Embedding ──
  final EmbeddingService embeddingService = useMock
      ? MockEmbeddingService()
      : EmbeddingChannel();

  // ── RAG: Vector Store ──
  final vectorStore = VectorStore();

  // ── RAG: Indexer ──
  final documentIndexer = DocumentIndexer(
    embedder: embeddingService,
    vectorStore: vectorStore,
  );

  // ── RAG: Retriever + Context Builder ──
  final ragRetriever = RagRetriever(
    embedder: embeddingService,
    store: vectorStore,
  );
  final contextBuilder = const ContextBuilder();

  // ── Model Download / Loader ──
  final modelDownloader = ModelDownloader();
  await modelDownloader.initialize();
  final modelLoader = ModelLoader(
    downloader: modelDownloader,
    inferenceService: inferenceService,
  );

  runApp(
    SlmApp(
      inferenceService: inferenceService,
      modelLoader: modelLoader,
      documentIndexer: documentIndexer,
      ragRetriever: ragRetriever,
      contextBuilder: contextBuilder,
    ),
  );
}

/// Root widget for the SLM (Small Language Model) Chat application.
class SlmApp extends StatelessWidget {
  final InferenceService inferenceService;
  final ModelLoader modelLoader;
  final DocumentIndexer documentIndexer;
  final RagRetriever ragRetriever;
  final ContextBuilder contextBuilder;

  const SlmApp({
    super.key,
    required this.inferenceService,
    required this.modelLoader,
    required this.documentIndexer,
    required this.ragRetriever,
    required this.contextBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => ChatBloc(
        inferenceService: inferenceService,
        modelLoader: modelLoader,
        documentIndexer: documentIndexer,
        ragRetriever: ragRetriever,
        contextBuilder: contextBuilder,
      ),
      child: MaterialApp(
        title: 'SLM Chat',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.blue,
          useMaterial3: true,
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.blue,
          useMaterial3: true,
          brightness: Brightness.dark,
        ),
        themeMode: ThemeMode.system,
        home: const ChatScreen(),
      ),
    );
  }
}
