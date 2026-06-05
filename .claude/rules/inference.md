# rules/inference.md — LiteRT-LM Integration

## LiteRT-LM Overview

LiteRT-LM là thư viện Google cho on-device LLM inference, kế thừa từ MediaPipe LLM Inference API.

**Model format**: `.task` bundle (tokenizer + weights gói chung)
**Source**: Hugging Face — `google/gemma-4-2b-it-litert-lm` (hoặc `Gemma-4-E2B-it-litert-lm`)

---

## Platform Channel Design

### Channel Names (giữ consistent)

```dart
// Dart side
const _inferenceChannel = MethodChannel('com.app.offline_chat/inference');
const _inferenceEvents   = EventChannel('com.app.offline_chat/inference_stream');
```

### Dart API Contract

```dart
abstract class InferenceService {
  Future<void> loadModel(String modelPath);
  Stream<String> generateStream(List<Message> history, String prompt);
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
| `getModelInfo` | - | `{name, size, contextLen}` |

Streaming tokens qua **EventChannel** — mỗi event là 1 token string.

---

## Android (Kotlin) Bridge

```kotlin
// android/app/src/main/kotlin/.../InferencePlugin.kt
class InferencePlugin(private val context: Context) :
    MethodCallHandler, EventChannel.StreamHandler {

    private var llmInference: LlmInference? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadModel" -> {
                val path = call.argument<String>("path")!!
                val options = LlmInference.LlmInferenceOptions.builder()
                    .setModelPath(path)
                    .setMaxTokens(1024)
                    .setResultListener { partial, done ->
                        mainHandler.post {
                            eventSink?.success(partial)
                            if (done) eventSink?.success("[DONE]")
                        }
                    }
                    .build()
                llmInference = LlmInference.createFromOptions(context, options)
                result.success(null)
            }
            "startGeneration" -> {
                val prompt = call.argument<String>("prompt")!!
                llmInference?.generateResponseAsync(prompt)
                result.success(null)
            }
            "resetSession" -> {
                // LiteRT-LM không có built-in session reset
                // → reload model hoặc manage context manually
                result.success(null)
            }
        }
    }
}
```

**Dependency** (android/app/build.gradle):
```gradle
implementation 'com.google.mediapipe:tasks-genai:0.10.x'
```

---

## iOS (Swift) Bridge

```swift
// ios/Runner/InferencePlugin.swift
class InferencePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var llmInference: LlmInference?
    private var eventSink: FlutterEventSink?

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "loadModel":
            let args = call.arguments as! [String: Any]
            let path = args["path"] as! String
            let options = LlmInference.Options(modelPath: path)
            options.maxTokens = 1024
            llmInference = try? LlmInference(options: options)
            result(nil)
        case "startGeneration":
            let args = call.arguments as! [String: Any]
            let prompt = args["prompt"] as! String
            llmInference?.generateResponseAsync(inputText: prompt) { [weak self] partial, error, done in
                DispatchQueue.main.async {
                    self?.eventSink?(partial ?? "")
                    if done { self?.eventSink?("[DONE]") }
                }
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
```

**Podfile**:
```ruby
pod 'MediaPipeTasksGenAI', '~> 0.10'
pod 'MediaPipeTasksGenAIC', '~> 0.10'
```

---

## Prompt Template (Gemma 4 Instruct)

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

---

## Context Window Management

- Gemma 4 2B: **8192 tokens** context window
- Giữ tối đa **~6000 tokens** để có room cho response
- Strategy: **sliding window** — drop oldest messages, luôn giữ system prompt

```dart
List<Message> trimHistory(List<Message> history, {int maxTokens = 6000}) {
  // Ước lượng: 1 token ≈ 4 chars (tiếng Anh), 3 chars (tiếng Việt)
  var total = 0;
  final result = <Message>[];
  for (final msg in history.reversed) {
    total += (msg.content.length / 3.5).ceil();
    if (total > maxTokens) break;
    result.insert(0, msg);
  }
  return result;
}
```

---

## Error Handling

| Error | Handling |
|-------|----------|
| Model file not found | Show download prompt |
| OOM (OutOfMemoryError) | Graceful error + suggest restart |
| Generation timeout (>60s) | Cancel + notify user |
| Corrupt model file | Delete + re-download |

---

## Performance Targets

| Metric | Target |
|--------|--------|
| Model load time | < 5s (cold), < 1s (warm) |
| First token latency | < 3s |
| Throughput | > 8 tokens/s (Android mid-range) |
| Memory footprint | < 3GB RAM |
