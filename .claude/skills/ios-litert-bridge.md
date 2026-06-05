# skills/ios-litert-bridge.md — Fix iOS LiteRT-LM Flutter Bridge

## When to Use

Reuse this skill when the iOS Flutter bridge fails to compile with errors like:
- `Type 'InferencePlugin' does not conform to protocol 'FlutterPlugin'`
- `LlmInference.Options has no member 'temperature'`
- `Missing argument for parameter 'completion' in call`
- Closure shape mismatch around `generateResponseAsync`

This applies to the project's pinned iOS SDK:
- `MediaPipeTasksGenAI 0.10.35`

## Root Cause

The Swift bridge may be written against an older MediaPipe / LiteRT-LM API.
In `0.10.35`:
- `FlutterPlugin` registration must use `FlutterPluginRegistrar`
- `LlmInference.Options` is engine-level
- `temperature`, `topk`, `topp` belong to `LlmInference.Session.Options`
- Async generation uses `generateResponseAsync(progress: completion:)`

## Reusable Fix Pattern

### 1. Register plugin via registrar

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

### 3. Create a session for each generation config

```swift
let sessionOptions = LlmInference.Session.Options()
sessionOptions.temperature = 0.7
sessionOptions.topk = 40

let session = try LlmInference.Session(llmInference: inference, options: sessionOptions)
try session.addQueryChunk(inputText: prompt)
```

### 4. Use separate progress and completion callbacks

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

### 5. Verify with a non-codesigned device build

```bash
flutter build ios --debug --no-codesign
```

## Notes

- Dispatch `eventSink` updates back to the main thread
- iOS simulator is not a reliable validation target for Core ML delegate behavior
- If rules and installed pod headers disagree, trust the pinned pod headers for exact Swift signatures
