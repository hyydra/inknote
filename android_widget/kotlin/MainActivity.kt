package com.example.inknote

import android.content.Context
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "inknote/widget").setMethodCallHandler { call, result ->
            if (call.method != "setNote") { result.notImplemented(); return@setMethodCallHandler }
            try {
                val title = call.argument<String>("title") ?: "InkNote"
                val base64 = call.argument<String>("png") ?: ""
                val bytes = Base64.decode(base64, Base64.DEFAULT)
                File(filesDir, "inknote_widget.png").writeBytes(bytes)
                getSharedPreferences("inknote_widget", Context.MODE_PRIVATE).edit().putString("title", title).apply()
                InkNoteWidget.updateAll(this)
                result.success(null)
            } catch (e: Exception) { result.error("widget", e.message, null) }
        }
    }
}
