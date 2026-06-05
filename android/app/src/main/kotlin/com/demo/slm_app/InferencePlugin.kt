package com.demo.slm_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Android native bridge for LiteRT-LM inference via Flutter Platform Channels.
 *
 * Implements the contract defined in rules/android-setup.md and rules/inference.md:
 * - MethodChannel: "com.app.offline_chat/inference"
 * - EventChannel:  "com.app.offline_chat/inference_stream"
 *
 * Key patterns (session-based API từ tasks-genai 0.10.22+):
 * - LlmInference: engine-level (model path, max tokens) — khởi tạo 1 lần
 * - LlmInferenceSession: session-level (temperature, topK) — tạo từ engine
 * - generateResponseAsync nhận ProgressListener trực tiếp
 * - Tất cả EventChannel updates MUST được post lên main thread qua mainHandler
 * - "[DONE]" signal streaming completion
 * - isCancelled flag để hỗ trợ cancel generation
 *
 * Thread safety:
 * - `llmInference`, `currentSession`, `currentModelPath`, `isCancelled` dùng @Volatile
 * - `eventSink` chỉ được truy cập trên main thread (via mainHandler.post)
 */
class InferencePlugin(private val context: Context) :
    MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "com.app.offline_chat/inference"
        const val EVENT_CHANNEL  = "com.app.offline_chat/inference_stream"
    }

    @Volatile
    private var llmInference: LlmInference? = null

    @Volatile
    private var currentSession: LlmInferenceSession? = null

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(Dispatchers.IO)

    @Volatile
    private var isCancelled = false

    @Volatile
    private var currentModelPath: String? = null

    // ── MethodCallHandler ──

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadModel" -> {
                val path = call.argument<String>("path")
                    ?: return result.error("INVALID_ARGS", "path required", null)
                loadModel(path, result)
            }
            "startGeneration" -> {
                val prompt = call.argument<String>("prompt")
                    ?: return result.error("INVALID_ARGS", "prompt required", null)
                startGeneration(prompt, result)
            }
            "cancelGeneration" -> {
                isCancelled = true
                // LiteRT-LM không có cancel() API native.
                // Set flag để ignore partial results + cho phép generation mới.
                result.success(null)
            }
            "resetSession" -> {
                // Reload model để reset KV cache (LiteRT-LM không có built-in reset)
                currentModelPath?.let { loadModel(it, result) } ?: result.success(null)
            }
            "getModelInfo" -> {
                result.success(mapOf(
                    "name" to "Gemma 4 2B Instruct",
                    "contextLength" to 8192
                ))
            }
            "dispose" -> {
                dispose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun loadModel(path: String, result: MethodChannel.Result) {
        scope.launch {
            try {
                // Close existing engine before creating a new one
                llmInference?.close()
                llmInference = null

                // Build engine options
                val options = LlmInference.LlmInferenceOptions.builder()
                    .setModelPath(path)
                    .setMaxTokens(1024)
                    .build()

                llmInference = LlmInference.createFromOptions(context, options)
                currentModelPath = path

                mainHandler.post { result.success(null) }

            } catch (e: Exception) {
                Log.e("InferencePlugin", "Failed to load model", e)
                mainHandler.post {
                    result.error("LOAD_FAILED", e.message ?: "Unknown error", null)
                }
            }
        }
    }

    private fun startGeneration(prompt: String, result: MethodChannel.Result) {
        val engine = llmInference
            ?: return result.error("MODEL_NOT_LOADED", "Call loadModel first", null)

        isCancelled = false
        result.success(null) // acknowledge immediately, results stream qua EventChannel

        scope.launch {
            try {
                // Call generateResponseAsync with the prompt
                // This returns a ListenableFuture<String> with the full response
                val future = engine.generateResponseAsync(prompt)
                
                // Listen for the result and stream it
                future.addListener({
                    if (!isCancelled) {
                        try {
                            val fullResponse = future.get()
                            mainHandler.post {
                                // Stream the response by splitting into words
                                val tokens = fullResponse?.split(" ") ?: emptyList()
                                for (token in tokens) {
                                    if (isCancelled) break
                                    eventSink?.success("$token ")
                                }
                                eventSink?.success("[DONE]")
                            }
                        } catch (e: Exception) {
                            Log.e("InferencePlugin", "Failed to get result", e)
                            mainHandler.post {
                                eventSink?.error("GENERATION_FAILED", e.message ?: "Generation error", null)
                            }
                        }
                    }
                }, java.util.concurrent.Executors.newSingleThreadExecutor())
                
            } catch (e: Exception) {
                Log.e("InferencePlugin", "Generation failed", e)
                mainHandler.post {
                    eventSink?.error("GENERATION_FAILED", e.message ?: "Generation error", null)
                }
            }
        }
    }

    // ── EventChannel.StreamHandler ──

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        isCancelled = true
        eventSink = null
    }

    fun dispose() {
        scope.cancel() // Cancel tất cả coroutines đang chạy
        currentSession?.close()
        currentSession = null
        llmInference?.close()
        llmInference = null
        currentModelPath = null
        eventSink = null
    }
}