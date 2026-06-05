# skills/ios-litert-bridge.md — iOS LiteRT-LM Bridge Guidance

## When to Use

Use this guidance when:
- the iOS LiteRT-LM bridge fails to compile
- the bridge emits incorrect streaming behavior
- generation/session lifecycle is unclear
- background or cancellation cleanup needs to be aligned with the app workflow

This applies to the pinned project SDK family:
- `MediaPipeTasksGenAI 0.10.35`

## Key API Facts

- `FlutterPlugin` registration must use `FlutterPluginRegistrar`
- `LlmInference.Options` is engine-level only
- `temperature`, `topk`, and `topp` belong to `LlmInference.Session.Options`
- async generation uses `generateResponseAsync(progress: completion:)`

## Reusable Fix Pattern

### 1. Register via registrar

```swift
static func register(with registrar: FlutterPluginRegistrar) {
    let instance = InferencePlugin(messenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: instance.methodChannel)
    instance.eventChannel.setStreamHandler(instance)
}
```

### 2. Keep engine options minimal

```swift
let options = LlmInference.Options(modelPath: path)
options.maxTokens = 1024
options.maxTopk = 40
let inference = try LlmInference(options: options)
```

### 3. Create a session per generation request

```swift
let sessionOptions = LlmInference.Session.Options()
sessionOptions.temperature = 0.7
sessionOptions.topk = 40

let session = try LlmInference.Session(llmInference: inference, options: sessionOptions)
try session.addQueryChunk(inputText: prompt)
```

### 4. Emit raw partials, not UI-batched text

```swift
try session.generateResponseAsync(
    progress: { [weak self] partial, error in
        DispatchQueue.main.async {
            if let partial { self?.eventSink?(partial) }
        }
    },
    completion: { [weak self] in
        DispatchQueue.main.async {
            self?.eventSink?("[DONE]")
        }
    }
)
```

The bridge should emit transport-level partials.
Dart decides how to batch those partials for UI state.

### 5. Clean up session references deterministically

- clear `currentSession` on completion
- clear `currentSession` on error
- clear `currentSession` on cancellation
- avoid emitting stale partials after cancel or release

### 6. Support lifecycle-aware release

If the app releases model resources on background:
- cancel active generation first
- clear session references
- release the inference instance safely
- avoid sending events after teardown

### 7. Validate with a device build

```bash
flutter build ios --debug --no-codesign
```

## Notes

- Always dispatch `eventSink` calls on the main thread
- iOS simulator is not a reliable proxy for Core ML delegate behavior
- If rules and installed pod headers disagree, trust the pinned pod headers for exact Swift signatures
