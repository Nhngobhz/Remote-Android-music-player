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
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/**
 * Runs yt-dlp for lib/services/ytdlp_service.dart, which decides the options. youtubedl-android
 * bundles yt-dlp with Python and QuickJS, which yt-dlp uses to solve YouTube's JavaScript
 * challenges.
 *
 * Runs may overlap, so a playlist lookup doesn't wait for a long download, but an update waits
 * for every run to finish so it never replaces the yt-dlp file while a run is using it.
 */
object YtDlpBridge {
    private const val CHANNEL = "music_contoller/ytdlp"
    private const val TAG = "YtDlp"

    private val workers = Executors.newCachedThreadPool()
    private val mainThread = Handler(Looper.getMainLooper())
    private val canceled = Collections.synchronizedSet(mutableSetOf<String>())

    // Fair, so a waiting update isn't held off by runs that keep starting.
    private val ytDlpFiles = ReentrantReadWriteLock(true)
    private var channel: MethodChannel? = null
    @Volatile private var initialized = false

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
                ytDlpFiles.write {
                    val status = YoutubeDL.updateYoutubeDL(context, YoutubeDL.UpdateChannel.STABLE)
                    mapOf(
                        "updated" to (status == YoutubeDL.UpdateStatus.DONE),
                        "version" to YoutubeDL.version(context),
                    )
                }
            }
            "run" -> {
                val id = call.argument<String>("id")!!
                val url = call.argument<String>("url")!!
                val options = call.argument<List<String>>("options")!!
                val reportLines = call.argument<Boolean>("reportLines") ?: true
                onWorker(result) {
                    ensureInit(context)
                    ytDlpFiles.read { run(id, url, options, reportLines) }
                }
            }
            "cancel" -> {
                val id = call.argument<String>("id")!!
                canceled.add(id) // In case the run hasn't started yet.
                // Kills the process tree through a shell, so keep it off the main thread.
                Thread { YoutubeDL.destroyProcessById(id) }.start()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun ensureInit(context: Context) {
        if (initialized) return
        ytDlpFiles.write {
            if (!initialized) {
                YoutubeDL.init(context) // Unpacks Python on first run, which takes a few seconds.
                initialized = true
            }
        }
    }

    /** Returns what yt-dlp printed to stdout. */
    private fun run(id: String, url: String, options: List<String>, reportLines: Boolean): String {
        try {
            if (canceled.contains(id)) throw YoutubeDL.CanceledException()
            val request = YoutubeDLRequest(url).apply { addCommands(options) }
            // Called for every output line, so it also tells Dart that yt-dlp is still alive.
            val onLine: ((Float, Long, String) -> Unit)? = if (!reportLines) null else { _, _, line ->
                Log.d(TAG, line)
                mainThread.post { channel?.invokeMethod("line", mapOf("id" to id, "line" to line)) }
            }
            val response = YoutubeDL.execute(request, id, onLine)
            // Warnings, such as a subtitle that couldn't be fetched.
            if (response.err.isNotBlank()) Log.w(TAG, response.err.trim())
            return response.out
        } finally {
            canceled.remove(id)
        }
    }

    private fun onWorker(result: MethodChannel.Result, task: () -> Any?) {
        workers.execute {
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
