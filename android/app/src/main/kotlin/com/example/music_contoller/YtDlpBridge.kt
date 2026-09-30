package com.example.music_contoller

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Collections
import java.util.concurrent.Executors

/**
 * Runs yt-dlp for lib/services/ytdlp_service.dart. youtubedl-android bundles yt-dlp with
 * Python and QuickJS, which yt-dlp uses to solve YouTube's JavaScript challenges.
 *
 * Every call runs on one background thread, so an update never replaces the yt-dlp file
 * while a download is using it.
 */
object YtDlpBridge {
    private const val CHANNEL = "music_contoller/ytdlp"
    private const val TAG = "YtDlp"

    private val worker = Executors.newSingleThreadExecutor()
    private val mainThread = Handler(Looper.getMainLooper())
    private val canceled = Collections.synchronizedSet(mutableSetOf<String>())
    private var channel: MethodChannel? = null
    private var initialized = false // Only touched on the worker thread.

    fun attach(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        channel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler { call, result -> handle(appContext, call, result) }
        }
    }

    private fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> onWorker(result) {
                ensureInit(context)
                YoutubeDL.version(context)
            }
            "update" -> onWorker(result) {
                ensureInit(context)
                val status = YoutubeDL.updateYoutubeDL(context, YoutubeDL.UpdateChannel.STABLE)
                mapOf(
                    "updated" to (status == YoutubeDL.UpdateStatus.DONE),
                    "version" to YoutubeDL.version(context),
                )
            }
            "download" -> {
                val id = call.argument<String>("id")!!
                val url = call.argument<String>("url")!!
                val dir = call.argument<String>("dir")!!
                onWorker(result) {
                    ensureInit(context)
                    download(id, url, dir)
                    null
                }
            }
            "cancel" -> {
                val id = call.argument<String>("id")!!
                canceled.add(id) // In case the download is still waiting for the worker.
                // Kills the process tree through a shell, so keep it off the main thread.
                Thread { YoutubeDL.destroyProcessById(id) }.start()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun ensureInit(context: Context) {
        if (initialized) return
        YoutubeDL.init(context) // Unpacks Python on first run, which takes a few seconds.
        initialized = true
    }

    private fun download(id: String, url: String, dir: String) {
        try {
            if (canceled.contains(id)) throw YoutubeDL.CanceledException()
            val request = YoutubeDLRequest(url).apply {
                addOption("--no-playlist")
                // AAC plays everywhere; any other audio-only stream is the fallback.
                addOption("-f", "bestaudio[ext=m4a]/bestaudio")
                addOption("-o", "$dir/audio.%(ext)s")
                // No ffmpeg is bundled, and the raw stream plays fine without a fixup.
                addOption("--fixup", "never")
                addOption("--newline")
                addOption("--progress-delta", "0.5")
                addOption("--socket-timeout", "30")
                addCommands(listOf(
                    "--print-to-file",
                    "after_move:%(.{title,uploader,channel,duration})j",
                    "$dir/info.json",
                ))
            }
            // Called for every output line, so it also tells Dart that yt-dlp is still alive.
            YoutubeDL.execute(request, id) { percent, _, line ->
                Log.d(TAG, line)
                mainThread.post {
                    channel?.invokeMethod(
                        "progress",
                        mapOf("id" to id, "percent" to percent.toDouble(), "line" to line),
                    )
                }
            }
        } finally {
            canceled.remove(id)
        }
    }

    private fun onWorker(result: MethodChannel.Result, task: () -> Any?) {
        worker.execute {
            try {
                val value = task()
                mainThread.post { result.success(value) }
            } catch (e: YoutubeDL.CanceledException) {
                mainThread.post { result.error("CANCELED", "Canceled", null) }
            } catch (e: Throwable) {
                // Errors too: a broken yt-dlp setup must not crash the app and stop the music.
                mainThread.post { result.error("FAILED", e.message ?: e.toString(), null) }
            }
        }
    }
}
