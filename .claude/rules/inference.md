# rules/inference.md — LiteRT-LM Integration

## Overview

LiteRT-LM is the on-device inference engine for this project.

- **Mobile artifact**: `.litertlm`
- **Web artifact**: `.task`
- **Preferred source**: `litert-community/gemma-4-E2B-it-litert-lm`
- **Pinned iOS SDK family**: `MediaPipeTasksGenAI 0.10.35`

This rule defines the platform-channel contract and how native streaming integrates with the higher-level generation pipeline.

## Lifecycle Boundary

Inference is responsible for **loading, generating, cancelling, resetting, and releasing** native model resources.
Inference is **not** responsible for deciding when to download a model or whether startup should prompt the user.

Required boundary:
- startup flow decides whether the model should be downloaded or preloaded
- model lifecycle service decides whether the model is downloaded and when to load/release it
- inference service only acts on an already available local model path

## Platform Channel Design

### Channel Names

```dart
const _inferenceChannel = MethodChannel('com.app.offline_chat/inference');
const _inferenceEvents = EventChannel('com.app.offline_chat/inference_stream');
```

### Dart API Contract

```dart
abstract class InferenceService {
  Future<void> loadModel(String modelPath);
  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 1024,
    double temperature = 0.7,
  });
  Future<void> cancelGeneration();
  Future<void> resetSession();
  Future<void> dispose();
  Future<ModelInfo> getModelInfo();
}
```

### Method Channel Methods

| Method | Params | Returns |
|--------|--------|---------|
| `loadModel` | `{path: String}` | `void` / throws |
| `startGeneration` | `{prompt: String, maxTokens: int, temp: double}` | `void` |
| `cancelGeneration` | - | `void` |
| `resetSession` | - | `void` |
| `dispose` | - | `void` |
| `getModelInfo` | - | `{name, size, contextLen}` |

### Streaming Contract

- Native code may emit partial results at token or sub-token cadence.
- The event channel carries raw partial text events plus a terminal completion signal.
- Dart may batch UI updates, but it must preserve token order.
- Completion, cancellation, and errors must flush any buffered partial text before final state transition.

## Generation Pipeline Integration

Inference participates only in the `Generate` stage of the application pipeline:

```text
EnsureModelLoaded
-> RetrieveContext (optional)
-> TokenBudgeting
-> Generate
-> Batch UI Updates
-> Finalize Message
```

The pipeline must satisfy these constraints:
- `loadModel()` must happen before `generateStream()`
- token budgeting happens before generation starts
- prompt serialization happens before generation starts
- UI batching happens after inference emits partials

## Prompt Template

Gemma 4 Instruct chat template:

```dart
String buildPrompt(List<Message> history, String systemPrompt) {
  final buf = StringBuffer();
  buf.write('<start_of_turn>system\n$systemPrompt<end_of_turn>\n');
  for (final msg in history) {
    final role = msg.isUser ? 'user' : 'model';
    buf.write('<start_of_turn>$role\n${msg.content}<end_of_turn>\n');
  }
  buf.write('<start_of_turn>model\n');
  return buf.toString();
}
```

## Token Budgeting Requirements

- Gemma 4 E2B supports an approximately 8192-token context window.
- Budget conversation history, retrieved context, and response headroom together.
- Do not rely on history trimming alone if RAG context is also injected.
- Prefer a dedicated budget allocator over ad hoc per-stage limits.

Recommended budgeting model:
- reserve response headroom first
- reserve fixed system-prompt cost
- cap retrieved context allocation
- fit remaining history using a sliding window

## Android Guidance

- Use `com.google.mediapipe:tasks-genai:0.10.35`
- Post listener callbacks back to the main thread before writing to `eventSink`
- Ensure cancellation does not emit stale partials after the user stops generation
- Ensure `dispose` releases the native inference instance

## iOS Guidance

- Use session-based generation for `temperature/topk/topp`
- Register via `FlutterPluginRegistrar`
- Use `generateResponseAsync(progress:completion:)`
- Dispatch `eventSink` writes back to the main thread
- Release session references when generation completes, errors, or is cancelled

## Error Handling

| Error | Handling |
|-------|----------|
| Model file missing | Surface download prompt via startup or send guard |
| Model load failure | Set error state and keep app recoverable |
| OOM / memory pressure | Release resources if possible and surface actionable error |
| Generation timeout | Cancel generation and finalize buffered text safely |
| Corrupt model file | Delete cache and require re-download |

## Performance Targets

| Metric | Target |
|--------|--------|
| Model load time | < 5s cold, < 1s warm |
| First token latency | < 3s |
| Throughput | > 8 tokens/s on a mid-range Android device |
| Memory footprint | Keep active model usage within device constraints |

## Validated Notes

- Mobile target file format is `.litertlm`
- Android callback delivery is not guaranteed on the main thread
- iOS `MediaPipeTasksGenAI 0.10.35` requires session-based generation
- If a higher-priority doc disagrees with an older example, follow the newer architecture docs plus validated SDK findings
