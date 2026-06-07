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
    private var lock = os_unfair_lock()
    private var _llmInference: LlmInference?
    private var _currentSession: LlmInference.Session?
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

    private var currentSession: LlmInference.Session? {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _currentSession }
        set { os_unfair_lock_lock(&lock); _currentSession = newValue; os_unfair_lock_unlock(&lock) }
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
    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = InferencePlugin(messenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: instance.methodChannel)
        instance.eventChannel.setStreamHandler(instance)
        registrar.publish(instance)
    }

    /// Required by FlutterPlugin protocol for plugin bundling
    static func dummyMethodToEnforceBundling() {
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
            let maxTokens = args["maxTokens"] as? Int ?? 1024
            let temperature = args["temp"] as? Double ?? 0.7
            startGeneration(prompt: prompt, maxTokens: maxTokens, temperature: temperature, result: result)

        case "cancelGeneration":
            // LiteRT-LM iOS chưa có cancel API → set flag để ignore tokens
            isCancelled = true
            currentSession = nil
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
                // Validate file exists and has reasonable size before loading
                let fileManager = FileManager.default
                guard fileManager.fileExists(atPath: path) else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "LOAD_FAILED",
                            message: "Model file not found at: \(path)",
                            details: nil
                        ))
                    }
                    return
                }
                
                let fileAttributes = try fileManager.attributesOfItem(atPath: path)
                let fileSize = fileAttributes[.size] as? UInt64 ?? 0
                let sizeMB = fileSize / 1024 / 1024
                print("[InferencePlugin] Loading model from: \(path) (size: \(fileSize) bytes, ~\(sizeMB) MB)")
                
                // Expected ~2.59 GB (2588147712 bytes)
                if fileSize < 2_000_000_000 {
                    print("[InferencePlugin] WARNING: Model file size seems too small: \(fileSize) bytes (expected ~2.59 GB)")
                }

                // Close existing inference instance trước khi tạo mới
                self.currentSession = nil
                self.llmInference = nil

                print("[InferencePlugin] Initializing LlmInference.Options for: \(path)")
                let options = LlmInference.Options(modelPath: path)
                
                // Engine-level maxTokens: set large enough to cover the full
                // prompt + response budget (prompt can be ~1-2K tokens for a
                // long conversation). Actual per-response limits are applied at
                // session creation time via Session.Options.
                options.maxTokens = 4096
                
                print("[InferencePlugin] Calling LlmInference constructor (this may take 10-30s for 2.6GB model)...")
                let startTime = CACurrentMediaTime()
                self.llmInference = try LlmInference(options: options)
                let endTime = CACurrentMediaTime()
                
                self.currentModelPath = path
                print("[InferencePlugin] Model loaded successfully in \(String(format: "%.2f", endTime - startTime))s")
                DispatchQueue.main.async { result(nil) }
            } catch {
                print("[InferencePlugin] Failed to load model: \(error)")
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "LOAD_FAILED",
                        message: "Load failed: \(error.localizedDescription)",
                        details: String(describing: error)
                    ))
                }
            }
        }
    }

    /// Starts a new session-based generation using the installed MediaPipeTasksGenAI 0.10.35 API.
    private func startGeneration(
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        result: @escaping FlutterResult
    ) {
        guard let inference = llmInference else {
            result(FlutterError(code: "MODEL_NOT_LOADED", message: "Call loadModel first", details: nil))
            return
        }

        isCancelled = false
        currentSession = nil
        result(nil) // acknowledge immediately

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let sessionOptions = LlmInference.Session.Options()
                sessionOptions.temperature = Float(temperature)
                sessionOptions.topk = 40
                // Apply the per-call maxTokens cap to limit how many tokens
                // the model generates for this specific request.
                // On iOS 0.10.35, maxNewTokens controls output length only.
                // Fallback: if the property does not exist on this SDK version,
                // the engine-level maxTokens (4096) acts as the hard ceiling.
                if #available(iOS 16.0, *) {
                    // sessionOptions.maxNewTokens = maxTokens  // uncomment if SDK supports it
                    _ = maxTokens  // placeholder — remove when SDK exposes this
                }
                let session = try LlmInference.Session(llmInference: inference, options: sessionOptions)
                try session.addQueryChunk(inputText: prompt)
                self.currentSession = session

                try session.generateResponseAsync(
                    progress: { [weak self] partialResult, error in
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
                            if let token = partialResult {
                                self.eventSink?(token)
                            }
                        }
                    },
                    completion: { [weak self] in
                        guard let self = self, !self.isCancelled else { return }
                        DispatchQueue.main.async {
                            self.currentSession = nil
                            self.eventSink?("[DONE]")
                        }
                    }
                )
            } catch {
                DispatchQueue.main.async {
                    self.currentSession = nil
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
        currentSession = nil
        self.eventSink = nil
        return nil
    }

    func dispose() {
        currentSession = nil
        llmInference = nil
        eventSink = nil
        currentModelPath = nil
    }

    deinit {
        dispose()
    }
}
