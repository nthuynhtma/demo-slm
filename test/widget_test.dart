import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:slm_app/core/channels/mock_inference_service.dart';
import 'package:slm_app/features/chat/bloc/chat_bloc.dart';
import 'package:slm_app/features/chat/screens/chat_screen.dart';

void main() {
  testWidgets('ChatScreen renders empty state with mock service',
      (WidgetTester tester) async {
    final mockService = MockInferenceService();
    await tester.pumpWidget(
      BlocProvider(
        create: (_) => ChatBloc(inferenceService: mockService),
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    // Verify empty state UI elements are shown.
    // The text is in a single Text widget with a newline separator.
    expect(find.textContaining('Gemma 4 2B'), findsOneWidget);
    expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}