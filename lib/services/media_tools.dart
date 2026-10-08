import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What [MediaTools.splitVideo] found in a file.
class VideoParts {
  const VideoParts({required this.hasVideo, required this.hasAudio, this.audio, this.durationMs});

  final bool hasVideo;
  final bool hasAudio;

  /// The sound, copied into a file of its own. Null when the file isn't a video with sound,
  /// or when its sound is in a codec that can't be copied without re-encoding.
  final File? audio;
  final int? durationMs;
}

/// Android's own media framework (MediaTools.kt), which needs no ffmpeg.
abstract final class MediaTools {
  static const _channel = MethodChannel('music_contoller/media');

  /// Looks at the streams in [video]. If it has both a picture and sound, the sound is
  /// copied, without re-encoding, to [output] plus an extension that fits it. Returns null
  /// when the phone can't read the file, or off Android.
  static Future<VideoParts?> splitVideo(File video, String output) async {
    try {
      final result = await _channel
          .invokeMapMethod<String, Object?>('splitVideo', {'input': video.path, 'output': output});
      if (result == null) return null;
      final audio = result['audio'] as String?;
      return VideoParts(
        hasVideo: result['hasVideo'] == true,
        hasAudio: result['hasAudio'] == true,
        audio: audio == null ? null : File(audio),
        durationMs: result['durationMs'] as int?,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('Could not look inside ${video.path}: ${e.message}');
      return null;
    }
  }
}
