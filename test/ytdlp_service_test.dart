import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_contoller/services/ytdlp_service.dart';

import 'fake_ytdlp.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory root;
  late YtDlpService ytDlp;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ytdlp_test');
    ytDlp = YtDlpService(workRoot: Directory('${root.path}/work'));
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(ytDlpChannel, null);
    await root.delete(recursive: true);
  });

  test('a download with video saves audio, video and subtitles, and reports overall progress', () async {
    final fake = FakeYtDlp()..subtitles = ['en', 'km'];
    addTearDown(fake.dispose);

    final progress = <double>[];
    final download =
        await ytDlp.download('https://www.youtube.com/watch?v=abc', video: true, onProgress: progress.add);

    // Subtitle lines don't count; the audio is the first tenth, the video the rest.
    expect(progress, [for (final p in [0.05, 0.1, 0.55, 1.0]) closeTo(p, 1e-9)]);
    expect(await download.audio.readAsBytes(), [1, 2, 3]);
    expect(await download.video!.readAsBytes(), [4, 5, 6, 7]);
    expect(download.subtitles.keys, unorderedEquals(['en', 'km']));
    expect(download.title, 'Test Song');
    expect(download.artist, 'Channel');
    expect(download.durationMs, 200000);

    final options = fake.runs.single.options;
    expect(options[options.indexOf('-f') + 1], contains(','), reason: 'audio and video are separate files');
    // Checked offline against yt-dlp 2026.08.19: 1080p30 H.264 when there is one, else
    // 1080p60, else 1080p VP9 rather than 720p H.264, and never above 1080p.
    expect(options[options.indexOf('-S') + 1], 'res:1080,fps:30,+vcodec:avc');
    expect(options, containsAll(['--write-subs', '--ignore-errors', '--no-overwrites']));
    expect(options, isNot(contains('--write-auto-subs')));

    await download.delete();
    expect(Directory('${root.path}/work').listSync(), isEmpty);
  });

  test('an audio-only download skips the video and subtitles', () async {
    final fake = FakeYtDlp();
    addTearDown(fake.dispose);

    final progress = <double>[];
    final download = await ytDlp.download('https://www.youtube.com/watch?v=abc', onProgress: progress.add);

    expect(progress, [0.5, 1.0]);
    expect(download.video, isNull);
    expect(download.subtitles, isEmpty);
    final options = fake.runs.single.options;
    expect(options[options.indexOf('-f') + 1], 'bestaudio[ext=m4a]/bestaudio');
    expect(options, isNot(anyOf(contains('--write-subs'), contains('-S'))));
  });

  test('download works without the info file and ignores leftovers', () async {
    messenger.setMockMethodCallHandler(ytDlpChannel, (call) async {
      final dir = FakeYtDlp.downloadDir(((call.arguments as Map)['options'] as List).cast());
      await File('$dir/audio.webm').writeAsBytes([1]);
      await File('$dir/video.mp4.part').writeAsBytes([1]);
      await File('$dir/audio.m4a.ytdl').writeAsBytes([1]);
      return '';
    });

    final download = await ytDlp.download('https://www.youtube.com/watch?v=abc', video: true);
    expect(download.audio.path, endsWith('audio.webm'));
    expect(download.video, isNull);
    expect(download.title, isNull);
  });

  test('a yt-dlp failure reports its ERROR line and cleans up', () async {
    final fake = FakeYtDlp();
    addTearDown(fake.dispose);
    fake.errors.add(PlatformException(
      code: 'FAILED',
      message: 'WARNING: [youtube] Some formats are missing\n'
          'ERROR: [youtube] kJQP7kiw5Fk: Video unavailable. This video has been removed\n',
    ));

    await expectLater(
      ytDlp.download('https://www.youtube.com/watch?v=kJQP7kiw5Fk', video: true),
      throwsA(isA<YtDlpException>()
          .having((e) => e.message, 'message', 'Video unavailable. This video has been removed')),
    );
    expect(Directory('${root.path}/work').listSync(), isEmpty);
  });

  test('a canceled run reports a stall', () async {
    final fake = FakeYtDlp();
    addTearDown(fake.dispose);
    fake.errors.add(PlatformException(code: 'CANCELED', message: 'Canceled'));

    await expectLater(ytDlp.download('https://www.youtube.com/watch?v=abc'), throwsA(isA<YtDlpStalled>()));
  });

  test('a run with no audio file is an error', () async {
    messenger.setMockMethodCallHandler(ytDlpChannel, (call) async => '');

    await expectLater(ytDlp.download('https://www.youtube.com/watch?v=abc'), throwsA(isA<YtDlpException>()));
    expect(Directory('${root.path}/work').listSync(), isEmpty);
  });

  test('without the Android bridge, downloads fail with a clear message', () async {
    await expectLater(
      ytDlp.download('https://www.youtube.com/watch?v=abc'),
      throwsA(isA<YtDlpException>().having((e) => e.message, 'message', contains('Android'))),
    );
  });

  test('listPlaylist reads the videos and skips private and deleted ones', () async {
    final fake = FakeYtDlp()
      ..playlistJson = 'WARNING: something\n'
          '{"title": "Khmer Karaoke", "entries": ['
          '{"id": "aaaaaaaaaaa", "title": "Song A", "url": "https://www.youtube.com/watch?v=aaaaaaaaaaa"},'
          '{"id": "bbbbbbbbbbb", "title": "[Private video]"},'
          '{"id": "ccccccccccc", "title": "[Deleted video]"},'
          '{"id": "ddddddddddd", "title": null}]}\n';
    addTearDown(fake.dispose);

    final playlist = await ytDlp.listPlaylist('https://www.youtube.com/playlist?list=PLx', limit: 300);

    expect(playlist.title, 'Khmer Karaoke');
    expect(playlist.videos.map((v) => (v.url, v.title)), [
      ('https://www.youtube.com/watch?v=aaaaaaaaaaa', 'Song A'),
      ('https://www.youtube.com/watch?v=ddddddddddd', null),
    ]);
    final options = fake.runs.single.options;
    expect(options, containsAll(['--flat-playlist', '--dump-single-json']));
    expect(options[options.indexOf('--playlist-items') + 1], '1:300');
  });

  test('search lists what YouTube finds, without live or upcoming streams', () async {
    final fake = FakeYtDlp()
      ..playlistJson = '{"title": "despacito", "entries": ['
          '{"id": "kJQP7kiw5Fk", "title": "Despacito", "channel": "Luis Fonsi", "duration": 282.0},'
          '{"id": "aaaaaaaaaaa", "title": "Despacito karaoke", "uploader": "Sing King", "duration": null},'
          '{"id": "bbbbbbbbbbb", "title": "Radio", "live_status": "is_live"},'
          '{"id": "ccccccccccc", "title": "Premiere", "live_status": "is_upcoming"}]}\n';
    addTearDown(fake.dispose);

    final results = await ytDlp.search('despacito', limit: 12);

    expect(results.map((v) => v.toJson()), [
      {
        'id': 'kJQP7kiw5Fk',
        'url': 'https://www.youtube.com/watch?v=kJQP7kiw5Fk',
        'title': 'Despacito',
        'channel': 'Luis Fonsi',
        'durationMs': 282000,
      },
      {
        'id': 'aaaaaaaaaaa',
        'url': 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
        'title': 'Despacito karaoke',
        'channel': 'Sing King',
        'durationMs': null,
      },
    ]);
    expect(fake.runs.single.url, 'ytsearch12:despacito');
    expect(fake.runs.single.options, containsAll(['--flat-playlist', '--dump-single-json']));
  });

  test('YtDlpProgress maps each stream to its share of the bar', () {
    final progress = YtDlpProgress(video: true);
    expect(progress.onLine('[download]  40.0% of 1MiB'), isNull, reason: 'no stream started yet');
    expect(progress.onLine('[download] Destination: /x/audio.en.vtt'), isNull);
    expect(progress.onLine('[download] 100.0% of 169.00B'), isNull, reason: 'subtitles');
    progress.onLine(r'[download] Destination: C:\x\audio.m4a');
    expect(progress.onLine('[download]  50.0% of 2MiB at 1MiB/s ETA 00:01'), closeTo(0.05, 1e-9));
    progress.onLine('[download] Destination: /x/video.webm');
    expect(progress.onLine('[download] 100% of 20MiB in 00:00:20'), closeTo(1.0, 1e-9));
    expect(progress.onLine('[info] Writing something'), isNull);
  });

  test('update reports the new version and shares one run between callers', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(ytDlpChannel, (call) async {
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
    messenger.setMockMethodCallHandler(ytDlpChannel, (call) async {
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
