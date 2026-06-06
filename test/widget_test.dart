import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:slm_app/core/channels/mock_inference_service.dart';
import 'package:slm_app/features/chat/bloc/chat_bloc.dart';
import 'package:slm_app/features/chat/screens/chat_screen.dart';
import 'package:slm_app/features/model_manager/loader/model_loader.dart';
import 'package:slm_app/features/model_manager/download/model_downloader.dart';

class FakeModelLoader implements ModelLoader {
  @override
  bool get isLoaded => true;

  @override
  Stream<ModelDownloadUpdate> get downloadUpdates => const Stream.empty();

  @override
  Future<ModelDownloadUpdate> getActiveDownloadUpdate() async =>
      const ModelDownloadUpdate(status: ModelDownloadStatus.none, progress: 0.0);

  @override
  Future<void> ensureModelLoaded({void Function(double progress)? onDownloadProgress}) async {}

  @override
  Future<void> unloadModel() async {}

  @override
  Future<List<String>> checkCompatibility() async => [];

  @override
  Future<bool> deleteModel() async => true;

  @override
  Future<void> downloadModel({
    String? url,
    String? expectedSha256,
  }) async {}

  @override
  Future<void> pauseDownload() async {}

  @override
  Future<void> resumeDownload() async {}

  @override
  Future<void> cancelDownload() async {}

  @override
  Future<bool> isModelDownloaded() async => true;
}

void main() {
  testWidgets('ChatScreen renders empty state with mock service',
      (WidgetTester tester) async {
    final mockService = MockInferenceService();
    final fakeLoader = FakeModelLoader();
    await tester.pumpWidget(
      BlocProvider(
        create: (_) => ChatBloc(
          inferenceService: mockService,
          modelLoader: fakeLoader,
        ),
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    // Wait for async startup (StartupRequested dispatched in constructor)
    // to complete so the UI reaches the ready state with empty messages.
    await tester.pumpAndSettle();

    // Verify empty state UI elements are shown.
    // The text is in a single Text widget with a newline separator.
    expect(find.textContaining('Gemma 4 E2B'), findsOneWidget);
    expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
