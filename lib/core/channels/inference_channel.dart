import 'dart:async';
import 'package:flutter/services.dart';
import 'inference_service.dart';

/// Real implementation of [InferenceService] using Platform Channels
/// to communicate with native LiteRT-LM (Android Kotlin / iOS Swift).
///
/// Channel names follow the convention in rules/inference.md:
/// - MethodChannel: `com.app.offline_chat/inference`
/// - EventChannel:  `com.app.offline_chat/inference_stream`
///
/// Method Channel methods:
/// | Method              | Params                                      | Returns       |
/// |---------------------|---------------------------------------------|---------------|
/// | loadModel           | {path: String}                              | void / throws |
/// | startGeneration     | {prompt: String, maxTokens: int, temp: double} | void         |
/// | cancelGeneration    | -                                           | void          |
/// | resetSession        | -                                           | void          |
/// | getModelInfo        | -                                           | {name, size, contextLen} |
///
/// Streaming tokens via EventChannel — each event is 1 token string.
/// A special "[DONE]" event signals generation completion.
class InferenceChannel implements InferenceService {
  static const String _channelName = 'com.app.offline_chat/inference';
  static const String _eventChannelName =
      'com.app.offline_chat/inference_stream';

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  StreamSubscription<dynamic>? _streamSubscription;

  InferenceChannel()
      : _methodChannel = const MethodChannel(_channelName),
        _eventChannel = const EventChannel(_eventChannelName);

  @override
  Future<void> loadModel(String modelPath) async {
    await _methodChannel.invokeMethod<void>(
      'loadModel',
      {'path': modelPath},
    );
  }

  @override
  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 1024,
    double temperature = 0.7,
  }) {
    // Start generation via method channel
    _methodChannel.invokeMethod<void>('startGeneration', {
      'prompt': prompt,
      'maxTokens': maxTokens,
      'temp': temperature,
    });

    // Listen for streaming results via event channel.
    // The EventChannel emits partial tokens as strings.
    // "[DONE]" signals completion.
    final controller = StreamController<String>();

    _streamSubscription = _eventChannel
        .receiveBroadcastStream()
        .listen(
          (event) {
            final token = event as String;
            if (token == '[DONE]') {
              controller.close();
            } else {
              controller.add(token);
            }
          },
          onError: (error) {
            controller.addError(error);
            controller.close();
          },
          onDone: () {
            if (!controller.isClosed) {
              controller.close();
            }
          },
        );

    return controller.stream;
  }

  @override
  Future<void> cancelGeneration() async {
    await _streamSubscription?.cancel();
    await _methodChannel.invokeMethod<void>('cancelGeneration');
  }

  @override
  Future<void> resetSession() async {
    await _methodChannel.invokeMethod<void>('resetSession');
  }

  @override
  Future<void> dispose() async {
    await _streamSubscription?.cancel();
    await _methodChannel.invokeMethod<void>('dispose');
  }

  @override
  Future<ModelInfo> getModelInfo() async {
    final info = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'getModelInfo',
    );
    if (info == null) {
      throw Exception('Failed to get model info');
    }
    return ModelInfo(
      name: info['name'] as String? ?? 'Unknown',
      sizeBytes: info['size'] as int? ?? 0,
      contextLength: info['contextLen'] as int? ?? 8192,
    );
  }
}