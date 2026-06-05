# rules/android-setup.md — Android Configuration cho LiteRT-LM

## build.gradle (app level)

```gradle
// android/app/build.gradle
android {
    compileSdk 36
    defaultConfig {
        minSdk 26          // LiteRT-LM yêu cầu API 26+
        targetSdk 36
    }

    // Bắt buộc: loại bỏ file metadata để tránh conflict
    packagingOptions {
        resources {
            excludes += [
                'META-INF/LICENSE',
                'META-INF/LICENSE.md',
                'META-INF/NOTICE',
                'META-INF/NOTICE.md'
            ]
        }
    }

    // Cần cho LiteRT native libs
    aaptOptions {
        noCompress "litertlm", "bin"  // không nén model file mobile
    }
}

dependencies {
    // MediaPipe GenAI (LiteRT-LM)
    implementation 'com.google.mediapipe:tasks-genai:0.10.35'

    // Coroutines cho async
    implementation 'org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3'
}
```

---

## InferencePlugin.kt (Full)

```kotlin
// android/app/src/main/kotlin/com/app/offline_chat/InferencePlugin.kt
package com.app.offline_chat

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class InferencePlugin(private val context: Context) :
    MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "com.app.offline_chat/inference"
        const val EVENT_CHANNEL  = "com.app.offline_chat/inference_stream"
    }

    private var llmInference: LlmInference? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(Dispatchers.IO)
    private var isCancelled = false
    private var currentModelPath: String? = null

    // MARK: - MethodCallHandler
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
                result.success(null)
            }
            "resetSession" -> {
                // Reload để reset KV cache
                currentModelPath?.let { loadModel(it, result) } ?: result.success(null)
            }
            "getModelInfo" -> {
                result.success(mapOf(
                    "name" to "Gemma 4 E2B Instruct",
                    "contextLength" to 8192
                ))
            }
            else -> result.notImplemented()
        }
    }

    private fun loadModel(path: String, result: MethodChannel.Result) {
        scope.launch {
            try {
                llmInference?.close()

                val options = LlmInference.LlmInferenceOptions.builder()
                    .setModelPath(path)
                    .setMaxTokens(1024)
                    .setTemperature(0.8f)
                    .setTopK(40)
                    .setResultListener { partialResult, done ->
                        if (isCancelled) return@setResultListener
                        mainHandler.post {
                            eventSink?.success(partialResult)
                            if (done) eventSink?.success("[DONE]")
                        }
                    }
                    .setErrorListener { error ->
                        mainHandler.post {
                            eventSink?.error("GENERATION_ERROR", error.message, null)
                        }
                    }
                    .build()

                llmInference = LlmInference.createFromOptions(context, options)
                currentModelPath = path

                mainHandler.post { result.success(null) }

            } catch (e: Exception) {
                mainHandler.post {
                    result.error("LOAD_FAILED", e.message, null)
                }
            }
        }
    }

    private fun startGeneration(prompt: String, result: MethodChannel.Result) {
        val inference = llmInference
            ?: return result.error("MODEL_NOT_LOADED", "Call loadModel first", null)

        isCancelled = false
        result.success(null)  // acknowledge segera

        scope.launch {
            try {
                inference.generateResponseAsync(prompt)
            } catch (e: Exception) {
                mainHandler.post {
                    eventSink?.error("GENERATION_FAILED", e.message, null)
                }
            }
        }
    }

    // MARK: - StreamHandler
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        isCancelled = true
        eventSink = null
    }

    fun dispose() {
        llmInference?.close()
        llmInference = null
    }
}
```

---

## MainActivity.kt — Đăng ký Plugin

```kotlin
// android/app/src/main/kotlin/com/app/offline_chat/MainActivity.kt
package com.app.offline_chat

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var inferencePlugin: InferencePlugin

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        inferencePlugin = InferencePlugin(applicationContext)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            InferencePlugin.METHOD_CHANNEL
        ).setMethodCallHandler(inferencePlugin)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            InferencePlugin.EVENT_CHANNEL
        ).setStreamHandler(inferencePlugin)
    }

    override fun onDestroy() {
        inferencePlugin.dispose()
        super.onDestroy()
    }
}
```

---

## Model File Location trên Android

```dart
// Dart side
Future<String> getModelPath() async {
  final dir = await getApplicationSupportDirectory();
  return '${dir.path}/gemma-4-E2B-it.litertlm';
}
```

> ⚠️ Không để model trong `assets/` — Android không thể mmap file >2GB từ assets

---

## AndroidManifest.xml

```xml
<!-- android/app/src/main/AndroidManifest.xml -->
<manifest>
    <!-- Download model -->
    <uses-permission android:name="android.permission.INTERNET" />

    <!-- Tùy chọn: restrict download WiFi only -->
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />

    <application
        android:largeHeap="true"    <!-- Quan trọng: cho phép heap lớn hơn -->
        ...>
    </application>
</manifest>
```

---

## Minimum Requirements Android

| | Minimum | Recommended |
|--|---------|-------------|
| API level | 26 (Android 8) | 30+ (Android 11) |
| RAM | 4GB | 6GB+ |
| Storage free | 3GB | 5GB+ |
| ABI | arm64-v8a | arm64-v8a |
| GPU | Adreno 6xx / Mali G7x | Adreno 7xx+ |

> ⚠️ x86/x86_64 emulator **không hỗ trợ** NNAPI → chỉ test trên physical device ARM64
