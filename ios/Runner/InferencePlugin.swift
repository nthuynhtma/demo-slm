import Flutter
import MediaPipeTasksGenAI
import os

/// iOS native bridge for LiteRT-LM inference via Flutter Platform Channels.
///
/// Implements the contract defined in rules/ios-setup.md and rules/inference.md:
/// - MethodChannel: "com.app.offline_chat/inference"
/// - EventChannel:  "com.app.offline_chat/inference_stream"
///
/// Key patterns:
/// - LiteRT-LM callback runs on a background queue
/// - All EventChannel updates MUST be dispatched to the main thread
/// - "[DONE]" signals streaming completion
/// - isCancelled flag để hỗ trợ cancel generation
/// - Thread-safe property access via os_unfair_lock
class InferencePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    // MARK: - Properties
    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel

    // Thread-safe properties using unfair lock
    private let lock = os_unfair_lock()
    private var _llmInference: LlmInference?
    private var _eventSink: FlutterEventSink?
    private var _currentModelPath: String?
    private var _isCancelled = false

    private var llmInference: LlmInference? {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _llmInference }
        set { os_unfair_lock_lock(&lock); _llmInference = newValue; os_unfair_lock_unlock(&lock) }
    }

    private var eventSink: FlutterEventSink? {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _eventSink }
        set { os_unfair_lock_lock(&lock); _eventSink = newValue; os_unfair_lock_unlock(&lock) }
    }

    private var currentModelPath: String? {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _currentModelPath }
        set { os_unfair_lock_lock(&lock); _currentModelPath = newValue; os_unfair_lock_unlock(&lock) }
    }

    private var isCancelled: Bool {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _isCancelled }
        set { os_unfair_lock_lock(&lock); _isCancelled = newValue; os_unfair_lock_unlock(&lock) }
    }

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

        case "dispose":
            dispose()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Private
    private func loadModel(path: String, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Close existing inference instance trước khi tạo mới
                self.llmInference = nil

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
        result(nil) // acknowledge immediately

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

    func dispose() {
        llmInference = nil
        eventSink = nil
        currentModelPath = nil
    }

    deinit {
        dispose()
    }
}