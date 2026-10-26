package com.example.music_contoller

import android.os.Handler
import android.os.Looper
import android.os.Process
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var closing = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        YtDlpBridge.attach(this, messenger)
        MediaTools.attach(messenger)
        // The close button on the home screen, called once the music has stopped.
        MethodChannel(messenger, "music_contoller/app").setMethodCallHandler { call, result ->
            if (call.method == "close") {
                closing = true
                result.success(null)
                finishAndRemoveTask()
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        // The Flutter engine outlives the screen (the music service keeps it), so end the
        // process too. That also stops yt-dlp, and the next start is a fresh one. Posted, so
        // the screen finishes closing first.
        if (closing) Handler(Looper.getMainLooper()).post { Process.killProcess(Process.myPid()) }
    }
}
