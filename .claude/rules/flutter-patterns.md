# rules/flutter-patterns.md — Flutter Conventions

## State Management

Dùng **flutter_bloc** (Bloc/Cubit). Không dùng Provider hay Riverpod trong project này.

```
ChatBloc         → quản lý messages, loading, streaming, error
ModelBloc        → model download/loading state  
RagBloc          → index documents, retrieval status
SettingsCubit    → temperature, max tokens, system prompt
```

## Bloc Pattern — Chat

```dart
// State
@freezed
class ChatState with _$ChatState {
  const factory ChatState({
    @Default([]) List<Message> messages,
    @Default(false) bool isGenerating,
    @Default(false) bool isModelLoaded,
    String? streamingBuffer,   // token đang stream
    AppError? error,
  }) = _ChatState;
}

// Events
abstract class ChatEvent {}
class SendMessage extends ChatEvent { final String text; }
class TokenReceived extends ChatEvent { final String token; }
class GenerationDone extends ChatEvent {}
class ClearHistory extends ChatEvent {}
```

## Streaming UI Pattern

```dart
// Dùng StreamBuilder wrap bubble cuối
StreamBuilder<String>(
  stream: _chatCubit.tokenStream,
  builder: (context, snapshot) {
    return ChatBubble(
      text: state.messages.last.content + (snapshot.data ?? ''),
      isStreaming: true,
    );
  },
)
```

## Error Handling Convention

```dart
// Dùng sealed class cho domain errors
sealed class InferenceError {
  const InferenceError();
}
class ModelNotLoaded extends InferenceError {}
class OutOfMemory extends InferenceError {}
class GenerationTimeout extends InferenceError {}
class ModelCorrupted extends InferenceError {}
```

## Platform Channel Conventions

- Tất cả Platform Channel calls wrap trong try/catch PlatformException
- Throw domain-specific exceptions, không expose PlatformException ra UI
- Channel methods đều async, không block UI thread

```dart
// Wrapper pattern
class InferenceChannelImpl implements InferenceService {
  static const _channel = MethodChannel('com.app.offline_chat/inference');

  @override
  Future<void> loadModel(String path) async {
    try {
      await _channel.invokeMethod('loadModel', {'path': path});
    } on PlatformException catch (e) {
      if (e.code == 'MODEL_NOT_FOUND') throw ModelNotLoaded();
      if (e.code == 'OOM') throw OutOfMemory();
      rethrow;
    }
  }
}
```

## File & Folder Naming

```
features/chat/
  ├── bloc/
  │   ├── chat_bloc.dart
  │   ├── chat_event.dart
  │   └── chat_state.dart
  ├── models/
  │   └── message.dart
  ├── widgets/
  │   ├── chat_bubble.dart
  │   ├── message_input.dart
  │   └── streaming_indicator.dart
  └── screens/
      └── chat_screen.dart
```

## Dependency Injection

Dùng `get_it` + `injectable`.

```dart
@singleton
class InferenceService { ... }

@singleton
class RagRetriever { ... }

@injectable  // per-use, not singleton
class ChatBloc { ... }
```

## Key Dependencies

```yaml
dependencies:
  flutter_bloc: ^8.x
  freezed_annotation: ^2.x
  get_it: ^7.x
  injectable: ^2.x
  sqlite_async: ^0.x
  sqlite_vec: ^0.x
  file_picker: ^6.x
  path_provider: ^2.x
  dio: ^5.x             # model download với progress
  crypto: ^3.x          # checksum verification

dev_dependencies:
  freezed: ^2.x
  injectable_generator: ^2.x
  build_runner: ^2.x
  flutter_test:
    sdk: flutter
```

## Mock-First Development

```dart
// Dùng dart-define để switch mock/real
// flutter run --dart-define=USE_MOCK=true

@injectable
@Environment('mock')
class MockInferenceService implements InferenceService {
  @override
  Stream<String> generateStream(List<Message> history, String prompt) async* {
    final response = 'Đây là response mock cho: "$prompt"';
    for (final word in response.split(' ')) {
      yield '$word ';
      await Future.delayed(const Duration(milliseconds: 80));
    }
  }
}
```
