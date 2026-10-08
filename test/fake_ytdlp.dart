import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const ytDlpChannel = MethodChannel('music_contoller/ytdlp');

/// Stands in for YtDlpBridge.kt, answering 'run' calls the way yt-dlp does with the
/// options YtDlpService sends (checked against yt-dlp 2026.08.19).
class FakeYtDlp {
  FakeYtDlp() {
    _messenger.setMockMethodCallHandler(ytDlpChannel, _handle);
  }

  final _messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Every run, in order.
  final runs = <({String url, List<String> options})>[];

  /// Thrown by the next runs, one each, before they write anything.
  final errors = <PlatformException>[];

  /// What a playlist run prints.
  String playlistJson = '{"title": "Empty", "entries": []}';

  /// Subtitle languages a download with video saves.
  List<String> subtitles = ['en'];

  /// Video title yt-dlp reports.
  String title = 'Test Song';

  void dispose() => _messenger.setMockMethodCallHandler(ytDlpChannel, null);

  /// Sends an output line for run [id], as the bridge does while yt-dlp works.
  Future<void> sendLine(String id, String line) => _messenger.handlePlatformMessage(
      ytDlpChannel.name,
      ytDlpChannel.codec.encodeMethodCall(MethodCall('line', {'id': id, 'line': line})),
      (_) {});

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != 'run') return null;
    final args = call.arguments as Map;
    final options = (args['options'] as List).cast<String>();
    runs.add((url: args['url'] as String, options: options));
    if (errors.isNotEmpty) throw errors.removeAt(0);
    if (options.contains('--flat-playlist')) return playlistJson;

    final id = args['id'] as String;
    final dir = downloadDir(options);
    final video = options.contains('--write-subs');
    for (final language in video ? subtitles : const <String>[]) {
      await sendLine(id, '[download] Destination: $dir/audio.$language.vtt');
      await sendLine(id, '[download] 100% of   169.00B in 00:00:00 at 4.43KiB/s');
      await File('$dir/subs.$language.vtt').writeAsString('WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n$language\n');
    }
    await sendLine(id, '[download] Destination: $dir/audio.m4a');
    await sendLine(id, '[download]  50.0% of    2.00MiB at  1.00MiB/s ETA 00:01');
    await sendLine(id, '[download] 100% of    2.00MiB in 00:00:02 at 1.00MiB/s');
    await File('$dir/audio.m4a').writeAsBytes([1, 2, 3]);
    final info = '{"title": "$title", "uploader": "Uploader", "channel": "Channel", "duration": 200}\n';
    await File('$dir/info.json').writeAsString(info, mode: FileMode.append);
    if (video) {
      await sendLine(id, '[download] Destination: $dir/video.mp4');
      await sendLine(id, '[download]  50.0% of   20.00MiB at  1.00MiB/s ETA 00:10');
      await sendLine(id, '[download] 100% of   20.00MiB in 00:00:20 at 1.00MiB/s');
      await File('$dir/video.mp4').writeAsBytes([4, 5, 6, 7]);
      await File('$dir/info.json').writeAsString(info, mode: FileMode.append);
    }
    return '';
  }

  /// The folder a download run saves into, read from its --print-to-file option.
  static String downloadDir(List<String> options) =>
      File(options[options.indexOf('--print-to-file') + 2]).parent.path;
}
