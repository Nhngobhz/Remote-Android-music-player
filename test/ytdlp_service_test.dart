import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_contoller/services/ytdlp_service.dart';

const channel = MethodChannel('music_contoller/ytdlp');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory root;
  late YtDlpService ytDlp;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ytdlp_test');
    ytDlp = YtDlpService(workRoot: root);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  /// Sends a progress line the way YtDlpBridge.kt does.
  Future<void> sendProgress(String id, double percent) => messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('progress', {'id': id, 'percent': percent, 'line': ''})),
      (_) {});

  test('download returns the saved audio file with the metadata yt-dlp reported', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'download');
      final args = call.arguments as Map;
      expect(args['url'], 'https://www.youtube.com/watch?v=abc');
      final dir = args['dir'] as String;
      await sendProgress(args['id'] as String, -1); // extraction lines come before any progress
      await sendProgress(args['id'] as String, 42.5);
      await File('$dir/audio.m4a').writeAsBytes([1, 2, 3]);
      await File('$dir/info.json')
          .writeAsString('{"title": "Despacito", "uploader": "LuisFonsiVEVO", "channel": "Luis Fonsi", "duration": 282}\n');
      return null;
    });

    final progress = <double>[];
    final download = await ytDlp.download('https://www.youtube.com/watch?v=abc', onProgress: progress.add);

    expect(progress, [0.425]);
    expect(download.extension, 'm4a');
    expect(await download.file.readAsBytes(), [1, 2, 3]);
    expect(download.title, 'Despacito');
    expect(download.artist, 'Luis Fonsi');
    expect(download.durationMs, 282000);

    await download.delete();
    expect(await download.file.parent.exists(), isFalse);
  });

  test('download works without the info file', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      await File('${(call.arguments as Map)['dir']}/audio.webm').writeAsBytes([1]);
      return null;
    });

    final download = await ytDlp.download('https://www.youtube.com/watch?v=abc');
    expect(download.extension, 'webm');
    expect(download.title, isNull);
  });

  test('a yt-dlp failure reports its ERROR line and cleans up', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      await File('${(call.arguments as Map)['dir']}/audio.m4a.part').writeAsBytes([1]);
      throw PlatformException(
        code: 'FAILED',
        message: 'WARNING: [youtube] Some formats are missing\n'
            'ERROR: [youtube] kJQP7kiw5Fk: Video unavailable. This video has been removed\n',
      );
    });

    await expectLater(
      ytDlp.download('https://www.youtube.com/watch?v=kJQP7kiw5Fk'),
      throwsA(isA<YtDlpException>()
          .having((e) => e.message, 'message', 'Video unavailable. This video has been removed')),
    );
    expect(root.listSync(), isEmpty);
  });

  test('a canceled download reports a stall', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'CANCELED', message: 'Canceled');
    });

    await expectLater(ytDlp.download('https://www.youtube.com/watch?v=abc'), throwsA(isA<YtDlpStalled>()));
  });

  test('a run with no audio file is an error', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);

    await expectLater(ytDlp.download('https://www.youtube.com/watch?v=abc'), throwsA(isA<YtDlpException>()));
    expect(root.listSync(), isEmpty);
  });

  test('update reports the new version and shares one run between callers', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return {'updated': true, 'version': '2026.09.20'};
    });

    final results = await Future.wait([ytDlp.update(), ytDlp.update()]);
    expect(results, [true, true]);
    expect(calls, 1);
    expect(ytDlp.version, '2026.09.20');
    expect(ytDlp.updating, isFalse);
  });

  test('a failed update is remembered and thrown', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'FAILED', message: 'failed to download');
    });

    await expectLater(ytDlp.update(), throwsA(isA<StateError>()));
    expect(ytDlp.toJson()['updateError'], 'failed to download');
  });

  test('errorMessage falls back to the last line when there is no ERROR line', () {
    expect(YtDlpService.errorMessage('something odd\nTraceback: boom\n'), 'Traceback: boom');
    expect(YtDlpService.errorMessage(null), 'yt-dlp failed without saying why');
  });
}
