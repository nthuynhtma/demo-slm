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
    let controller = window?.rootViewController as! FlutterViewController

    // Đăng ký InferencePlugin
    InferencePlugin.register(with: controller.binaryMessenger)

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

  // MARK: - Properties
  private var llmInference: LlmInference?
  private var eventSink: FlutterEventSink?
  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel

  // MARK: - Registration
  static func register(with messenger: FlutterBinaryMessenger) {
    let instance = InferencePlugin(messenger: messenger)
    instance.methodChannel.setMethodCallHandler(instance.handle)
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

  // MARK: - Method Handler
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {

    case "loadModel":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "path required", details: nil))
        return
      }
      loadModel(path: path, result: result)

    case "startGeneration":
      guard let args = call.arguments as? [String: Any],
            let prompt = args["prompt"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "prompt required", details: nil))
        return
      }
      startGeneration(prompt: prompt, result: result)

    case "cancelGeneration":
      // LiteRT-LM iOS chưa có cancel API → set flag để ignore tokens
      isCancelled = true
      result(nil)

    case "resetSession":
      // Reload model để reset KV cache
      if let path = currentModelPath {
        loadModel(path: path, result: result)
      } else {
        result(nil)
      }

    case "getModelInfo":
      result([
        "name": "Gemma 4 2B Instruct",
        "contextLength": 8192
      ])

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Private
  private var currentModelPath: String?
  private var isCancelled = false

  private func loadModel(path: String, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let options = LlmInference.Options(modelPath: path)
        options.maxTokens = 1024
        options.temperature = 0.8
        options.topK = 40

        self.llmInference = try LlmInference(options: options)
        self.currentModelPath = path

        DispatchQueue.main.async { result(nil) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "LOAD_FAILED",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    }
  }

  private func startGeneration(prompt: String, result: @escaping FlutterResult) {
    guard let inference = llmInference else {
      result(FlutterError(code: "MODEL_NOT_LOADED", message: "Call loadModel first", details: nil))
      return
    }

    isCancelled = false
    result(nil)  // acknowledge segera

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try inference.generateResponseAsync(inputText: prompt) { [weak self] partialResult, error, done in
          guard let self = self, !self.isCancelled else { return }

          DispatchQueue.main.async {
            if let error = error {
              self.eventSink?(FlutterError(
                code: "GENERATION_ERROR",
                message: error.localizedDescription,
                details: nil
              ))
              return
            }
            if let token = partialResult {
              self.eventSink?(token)
            }
            if done {
              self.eventSink?("[DONE]")
            }
          }
        }
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

  // MARK: - FlutterStreamHandler
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    isCancelled = true
    self.eventSink = nil
    return nil
  }
}
```

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
  return '${dir.path}/gemma-4-2b-it.task';
}
```

> ⚠️ Dùng `ApplicationSupport`, không dùng `Documents` — tránh iCloud backup model file 2GB+

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
