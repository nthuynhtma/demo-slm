import 'dart:async';
import 'inference_service.dart';

/// Mock implementation of [InferenceService] for testing the streaming UI
/// without requiring an actual LiteRT-LM model.
///
/// Simulates token-by-token generation with realistic timing.
class MockInferenceService implements InferenceService {
  bool _isLoaded = false;
  bool _cancelled = false;

  @override
  Future<void> loadModel(String modelPath) async {
    // Simulate model loading delay
    await Future.delayed(const Duration(seconds: 1));
    _isLoaded = true;
  }

  @override
  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 1024,
    double temperature = 0.7,
  }) async* {
    if (!_isLoaded) {
      throw Exception('Model not loaded. Call loadModel() first.');
    }

    _cancelled = false;

    // Simulate Gemma 4 2B response to common queries
    final response = _mockResponse(prompt);

    // Emit one token at a time with realistic delays
    final words = response.split(' ');
    for (int i = 0; i < words.length; i++) {
      if (_cancelled) break;

      // Simulate variable token generation speed (30-80ms per token)
      await Future.delayed(Duration(milliseconds: 30 + (i % 3) * 20));

      // Add space before subsequent words
      if (i > 0) {
        yield ' ';
      }
      yield words[i];
    }

  }

  @override
  Future<void> cancelGeneration() async {
    _cancelled = true;
  }

  @override
  Future<void> resetSession() async {
    // Mock: just reset internal state
    _cancelled = false;
  }

  @override
  Future<void> dispose() async {
    _isLoaded = false;
    _cancelled = false;
  }

  @override
  Future<ModelInfo> getModelInfo() async {
    return const ModelInfo(
      name: 'Gemma 4 E2B (Mock)',
      sizeBytes: 2_580_000_000, // ~2.58 GB
      contextLength: 8192,
    );
  }

  /// Generate a realistic mock response based on the prompt.
  String _mockResponse(String prompt) {
    final lower = prompt.toLowerCase();

    if (lower.contains('hello') || lower.contains('xin chào')) {
      return 'Hello! I am Gemma 4, an on-device AI assistant running entirely offline. How can I help you today?';
    }
    if (lower.contains('who are you') || lower.contains('what are you')) {
      return 'I am a Gemma 4 E2B Instruct model, running on your device via LiteRT-LM. I am completely offline and your data stays private on your device.';
    }
    if (lower.contains('weather')) {
      return 'I cannot check live weather data because I run entirely offline. However, I can help you understand weather concepts or work with provided reference documents!';
    }
    if (lower.contains('code') || lower.contains('flutter') || lower.contains('dart')) {
      return 'I can help you with Flutter and Dart development! LiteRT-LM and Gemma 4 support code generation tasks. Feel free to ask me to write Flutter widgets, Dart functions, or explain programming concepts.';
    }
    if (lower.contains('offline') || lower.contains('private') || lower.contains('privacy')) {
      return 'That is correct! I run fully on-device using LiteRT-LM inference engine and Gemma 4 E2B model. No data ever leaves your device. All inference, embeddings, and vector search happen locally. This is great for privacy-sensitive applications.';
    }
    if (lower.contains('capabilities') || lower.contains('can you') || lower.contains('help')) {
      return 'I can help with: conversation and Q&A, text generation and summarization, code writing and explanation, and working with your documents through RAG (Retrieval Augmented Generation). Just note I run fully offline so I cannot access the internet.';
    }

    // Default response
    return 'That is an interesting question. Based on my on-device knowledge from Gemma 4 E2B, I would say that running large language models locally gives you full privacy control and low latency. However, the model size is limited by device hardware. LiteRT-LM optimizes inference using GPU delegates like NNAPI on Android and Core ML on iOS.';
  }
}
