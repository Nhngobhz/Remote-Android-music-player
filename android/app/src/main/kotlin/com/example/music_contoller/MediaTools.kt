package com.example.music_contoller

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Android's own media framework for lib/services/media_tools.dart. There is no ffmpeg on the
 * phone, but MediaExtractor and MediaMuxer can copy a stream out of a video without re-encoding.
 */
object MediaTools {
    private const val CHANNEL = "music_contoller/media"
    private const val TAG = "MediaTools"

    private val worker = Executors.newSingleThreadExecutor()
    private val mainThread = Handler(Looper.getMainLooper())

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "splitVideo" -> {
                    val input = call.argument<String>("input")!!
                    val output = call.argument<String>("output")!!
                    worker.execute {
                        try {
                            val value = splitVideo(input, output)
                            mainThread.post { result.success(value) }
                        } catch (e: Throwable) {
                            mainThread.post { result.error("FAILED", e.message ?: e.toString(), null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Reports which streams [input] has. When it has both a picture and sound, the sound is
     * copied to [output] plus an extension that fits it; "audio" is that file's path, or null
     * when its codec can't be copied this way.
     */
    private fun splitVideo(input: String, output: String): Map<String, Any?> {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(input)
            var audioTrack = -1
            var hasVideo = false
            var durationUs = 0L
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) hasVideo = true
                if (mime.startsWith("audio/") && audioTrack < 0) audioTrack = i
                if (format.containsKey(MediaFormat.KEY_DURATION)) {
                    durationUs = maxOf(durationUs, format.getLong(MediaFormat.KEY_DURATION))
                }
            }
            val found = mapOf(
                "hasVideo" to hasVideo,
                "hasAudio" to (audioTrack >= 0),
                "durationMs" to (if (durationUs > 0) durationUs / 1000 else null),
            )
            if (!hasVideo || audioTrack < 0) return found
            val audio = try {
                copyTrack(extractor, audioTrack, output)
            } catch (e: Exception) {
                Log.w(TAG, "Could not copy the sound out of $input", e)
                null
            }
            return found + ("audio" to audio)
        } finally {
            extractor.release()
        }
    }

    /** Returns the new file's path, or null when MediaMuxer can't hold the track's codec. */
    private fun copyTrack(extractor: MediaExtractor, track: Int, output: String): String? {
        val format = extractor.getTrackFormat(track)
        val (container, extension) = when (format.getString(MediaFormat.KEY_MIME)) {
            MediaFormat.MIMETYPE_AUDIO_AAC -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4 to "m4a"
            MediaFormat.MIMETYPE_AUDIO_OPUS, MediaFormat.MIMETYPE_AUDIO_VORBIS ->
                MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM to "webm"
            else -> return null
        }
        val file = File("$output.$extension")
        val muxer = MediaMuxer(file.path, container)
        var done = false
        try {
            val target = muxer.addTrack(format)
            muxer.start()
            extractor.selectTrack(track)
            val maxSample =
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else 0
            val buffer = ByteBuffer.allocate(maxOf(maxSample, 256 * 1024))
            val info = MediaCodec.BufferInfo()
            var startUs: Long? = null
            while (true) {
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                val first = startUs ?: extractor.sampleTime.also { startUs = it }
                // MediaMuxer refuses times before zero, which some files start with.
                val timeUs = extractor.sampleTime - minOf(first, 0L)
                val sync = extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0
                info.set(0, size, timeUs, if (sync) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                muxer.writeSampleData(target, buffer, info)
                extractor.advance()
            }
            muxer.stop()
            done = true
            return file.path
        } finally {
            try {
                muxer.release()
            } catch (e: Exception) {
                // Already broken by the error being thrown.
            }
            if (!done) file.delete()
        }
    }
}
