# rules/ios-setup.md — iOS Configuration cho LiteRT-LM

## Podfile

```ruby
# ios/Podfile
platform :ios, '16.0'   # LiteRT-LM yêu cầu iOS 16+

target 'Runner' do
  use_frameworks!
  use_modular_headers!

  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))

  # MediaPipe GenAI cho LiteRT-LM
  pod 'MediaPipeTasksGenAI',  '~> 0.10'
  pod 'MediaPipeTasksGenAIC', '~> 0.10'
end
```

Sau khi sửa Podfile:
```bash
cd ios && pod install
```

---

## AppDelegate.swift — Đăng ký Plugin

```swift
// ios/Runner/AppDelegate.swift
import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Đăng ký InferencePlugin
    if let registrar = registrar(forPlugin: "InferencePlugin") {
      InferencePlugin.register(with: registrar)
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
```

---

## InferencePlugin.swift (Full)

```swift
// ios/Runner/InferencePlugin.swift
import Flutter
import MediaPipeTasksGenAI

class InferencePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var llmInference: LlmInference?
  private var currentSession: LlmInference.Session?
  private var eventSink: FlutterEventSink?
  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var currentModelPath: String?
  private var isCancelled = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = InferencePlugin(messenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: instance.methodChannel)
    instance.eventChannel.setStreamHandler(instance)
  }

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "com.app.offline_chat/inference",
      binaryMessenger: messenger
    )
    eventChannel = FlutterEventChannel(
      name: "com.app.offline_chat/inference_stream",
      binaryMessenger: messenger
    )
    super.init()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "loadModel":
      let path = (call.arguments as? [String: Any])?["path"] as? String
      loadModel(path: path ?? "", result: result)

    case "startGeneration":
      let args = call.arguments as? [String: Any]
      let prompt = args?["prompt"] as? String ?? ""
      let temperature = (args?["temp"] as? Double) ?? 0.7
      startGeneration(prompt: prompt, temperature: temperature, result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func loadModel(path: String, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let options = LlmInference.Options(modelPath: path)
        options.maxTokens = 1024
        options.maxTopk = 40

        self.llmInference = try LlmInference(options: options)
        self.currentModelPath = path
        DispatchQueue.main.async { result(nil) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "LOAD_FAILED", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func startGeneration(
    prompt: String,
    temperature: Double,
    result: @escaping FlutterResult
  ) {
    guard let inference = llmInference else {
      result(FlutterError(code: "MODEL_NOT_LOADED", message: "Call loadModel first", details: nil))
      return
    }

    isCancelled = false
    result(nil)

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let sessionOptions = LlmInference.Session.Options()
        sessionOptions.temperature = Float(temperature)
        sessionOptions.topk = 40

        let session = try LlmInference.Session(llmInference: inference, options: sessionOptions)
        try session.addQueryChunk(inputText: prompt)
        self.currentSession = session

        try session.generateResponseAsync(progress: { [weak self] partial, error in
          guard let self = self, !self.isCancelled else { return }
          DispatchQueue.main.async {
            if let error = error {
              self.currentSession = nil
              self.eventSink?(FlutterError(
                code: "GENERATION_ERROR",
                message: error.localizedDescription,
                details: nil
              ))
              return
            }
            if let partial = partial {
              self.eventSink?(partial)
            }
          }
        }, completion: { [weak self] in
          guard let self = self, !self.isCancelled else { return }
          DispatchQueue.main.async {
            self.currentSession = nil
            self.eventSink?("[DONE]")
          }
        })
      } catch {
        DispatchQueue.main.async {
          self.eventSink?(FlutterError(
            code: "GENERATION_FAILED",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    isCancelled = true
    currentSession = nil
    eventSink = nil
    return nil
  }
}
```

> ⚠️ Với `MediaPipeTasksGenAI 0.10.35`, `temperature` không nằm trong `LlmInference.Options`.
> Nó nằm trong `LlmInference.Session.Options`, và async generation cần `progress` + `completion`.

---

## Info.plist — Không cần entitlement đặc biệt

LiteRT-LM dùng Core ML framework có sẵn, **không cần** thêm entitlements.

Tuy nhiên nếu model lưu trong Documents (user-accessible):
```xml
<!-- ios/Runner/Info.plist -->
<key>UIFileSharingEnabled</key>
<true/>
<key>LSSupportsOpeningDocumentsInPlace</key>
<true/>
```

---

## Model File Location trên iOS

```dart
// Dart side — lấy đúng path cho iOS
Future<String> getModelPath() async {
  final dir = await getApplicationSupportDirectory(); // NOT Documents
  return '${dir.path}/gemma-4-E2B-it.litertlm';
}
```

> ⚠️ Dùng `ApplicationSupport`, không dùng `Documents` — tránh iCloud backup model file ~2.6GB

Thêm vào `Info.plist` để exclude khỏi backup:
```swift
// Sau khi download xong, set no-backup attribute
var url = URL(fileURLWithPath: modelPath)
try url.setResourceValues({
  var rv = URLResourceValues()
  rv.isExcludedFromBackup = true
  return rv
}())
```

---

## Core ML Delegate (tự động)

LiteRT-LM trên iOS tự dùng **Core ML** nếu device support (iPhone XS trở lên).
Không cần config thêm — framework tự fallback về CPU nếu Core ML không available.

---

## Minimum Requirements iOS

| | Minimum | Recommended |
|--|---------|-------------|
| iOS version | 16.0 | 17.0+ |
| RAM | 4GB | 6GB+ |
| Storage free | 3GB | 5GB+ |
| Device | iPhone XS | iPhone 14+ |
| Chip | A12 | A15+ |
