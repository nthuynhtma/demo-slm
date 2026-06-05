package com.demo.slm_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private lateinit var inferencePlugin: InferencePlugin

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize the LiteRT-LM inference bridge with application context
        inferencePlugin = InferencePlugin(applicationContext)

        // Register method channel for commands
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            InferencePlugin.METHOD_CHANNEL
        ).setMethodCallHandler(inferencePlugin)

        // Register event channel for streaming tokens
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