package com.example.music_contoller

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        YtDlpBridge.attach(this, flutterEngine.dartExecutor.binaryMessenger)
    }
}
