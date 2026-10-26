import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_contoller/models/music_folder.dart';
import 'package:music_contoller/models/track.dart';
import 'package:music_contoller/services/audio_player_service.dart';
import 'package:music_contoller/services/control_server.dart';
import 'package:music_contoller/services/library_service.dart';
import 'package:music_contoller/services/settings_service.dart';
import 'package:music_contoller/services/youtube_service.dart';
import 'package:music_contoller/services/ytdlp_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_media_tools.dart';

const pin = '123456';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding fakes every HttpClient; these tests need real requests to the local server.
  HttpOverrides.global = null;

  late Directory root;
  late LibraryService library;
  late ControlServer server;
  late HttpClient client;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.ryanheise.audio_session'), (_) async => null);
    SharedPreferences.setMockInitialValues({'pin': pin});
    root = await Directory.systemTemp.createTemp('server_test');
    library = LibraryService();
    await library.init(root: root);
    server = ControlServer(
      library: library,
      player: PlayerHandler(library),
      youtube: YoutubeService(library, YtDlpService(workRoot: Directory('${root.path}/work'))),
      settings: await SettingsService.load(),
    );
    await server.start(address: InternetAddress.loopbackIPv4);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await library.flush();
    await root.delete(recursive: true);
  });

  Future<(int, dynamic)> call(
    String method,
    String path, {
    Object? json,
    String? pinHeader = pin,
    String? contentType,
    List<int>? raw,
  }) async {
    final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
    if (pinHeader != null) req.headers.set('x-pin', pinHeader);
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(json));
    }
    if (contentType != null) req.headers.set('content-type', contentType);
    if (raw != null) req.add(raw);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    final isJson = res.headers.contentType?.mimeType == 'application/json';
    return (res.statusCode, isJson ? jsonDecode(text) : text);
  }

  test('serves the web controller without a PIN', () async {
    final (status, body) = await call('GET', '/', pinHeader: null);
    expect(status, 200);
    expect(body, contains('<title>Music Controller</title>'));
    expect((await call('GET', '/app.js', pinHeader: null)).$1, 200);
    expect((await call('GET', '/style.css', pinHeader: null)).$1, 200);
    expect((await call('GET', '/nope.html', pinHeader: null)).$1, 404);
  });

  test('API needs the PIN and locks out after repeated wrong guesses', () async {
    expect((await call('GET', '/api/ping', pinHeader: null)).$1, 401);
    for (var i = 0; i < 4; i++) {
      expect((await call('GET', '/api/ping', pinHeader: '000000')).$1, 401);
    }
    final (status, body) = await call('GET', '/api/ping');
    expect(status, 429, reason: 'even the right PIN is refused during lockout');
    expect(body['error'], contains('Too many'));
  });

  test('right PIN works and status has the shape the page expects', () async {
    expect((await call('GET', '/api/ping')).$1, 200);
    final (status, body) = await call('GET', '/api/status');
    expect(status, 200);
    expect(body['player']['playing'], false);
    expect(body['player']['track'], isNull);
    expect(body['player']['repeat'], 'all');
    expect(body['jobs'], isEmpty);
    expect(body['libraryVersion'], isA<int>());
  });

  test('folder create, rename, duplicate and delete', () async {
    final (created, folder) = await call('POST', '/api/folders', json: {'name': 'Morning'});
    expect(created, 201);

    final (dup, dupBody) = await call('POST', '/api/folders', json: {'name': 'morning'});
    expect(dup, 400);
    expect(dupBody['error'], contains('already exists'));

    expect((await call('PATCH', '/api/folders/${folder['id']}', json: {'name': 'Opening'})).$1, 200);
    final (_, lib) = await call('GET', '/api/library');
    expect((lib['folders'] as List).map((f) => f['name']), containsAll(['Unsorted', 'Opening']));

    expect((await call('DELETE', '/api/folders/${folder['id']}')).$1, 200);
    expect((await call('DELETE', '/api/folders/${MusicFolder.unsortedId}')).$1, 400);
  });

  test('multipart upload stores audio into the chosen folder and rejects other files', () async {
    final (_, folder) = await call('POST', '/api/folders', json: {'name': 'Uploads'});
    const boundary = 'testboundary123';
    final audioBytes = List<int>.generate(4096, (i) => i % 256);
    final body = <int>[
      ...utf8.encode('--$boundary\r\n'
          'Content-Disposition: form-data; name="file"; filename="My_Song.mp3"\r\n'
          'Content-Type: audio/mpeg\r\n\r\n'),
      ...audioBytes,
      ...utf8.encode('\r\n--$boundary\r\n'
          'Content-Disposition: form-data; name="file"; filename="notes.txt"\r\n'
          'Content-Type: text/plain\r\n\r\nhello\r\n'
          '--$boundary--\r\n'),
    ];

    final (status, result) = await call('POST', '/api/upload?folderId=${folder['id']}',
        contentType: 'multipart/form-data; boundary=$boundary', raw: body);
    expect(status, 200);
    expect(result['rejected'], ['notes.txt']);
    final added = (result['added'] as List).single;
    expect(added['title'], 'My Song');
    expect(added['folderId'], folder['id']);
    expect(added['source'], 'upload');

    final track = library.trackById(added['id'] as String)!;
    expect(await File(library.pathOf(track)).readAsBytes(), audioBytes);
  });

  test('upload without multipart is a clear 400', () async {
    final (status, body) = await call('POST', '/api/upload', json: {'x': 1});
    expect(status, 400);
    expect(body['error'], contains('multipart'));
  });

  test('track rename, move and delete', () async {
    final (_, folder) = await call('POST', '/api/folders', json: {'name': 'Target'});
    final track = await library.importStream(Stream.value([1, 2, 3]),
        extension: 'mp3', title: 'Old', source: TrackSource.upload);

    expect((await call('PATCH', '/api/tracks/${track.id}',
            json: {'title': 'New', 'folderId': folder['id']})).$1, 200);
    expect(library.trackById(track.id)!.title, 'New');
    expect(library.trackById(track.id)!.folderId, folder['id']);

    expect((await call('PATCH', '/api/tracks/${track.id}', json: {'folderId': 'missing'})).$1, 400);
    expect((await call('DELETE', '/api/tracks/${track.id}')).$1, 200);
    expect((await call('DELETE', '/api/tracks/${track.id}')).$1, 400);
  });

  test('YouTube endpoint rejects links that are not YouTube', () async {
    final (status, body) = await call('POST', '/api/youtube', json: {'url': 'https://example.com/song'});
    expect(status, 400);
    expect(body['error'], contains('not a YouTube'));
    expect((await call('POST', '/api/youtube', json: {})).$1, 400);
  });

  test('YouTube endpoint queues the video download when asked', () async {
    final (status, body) = await call('POST', '/api/youtube',
        json: {'url': 'https://youtu.be/kJQP7kiw5Fk', 'video': true});
    expect(status, 202);
    final job = (body['jobs'] as List).single;
    expect(job['url'], 'https://www.youtube.com/watch?v=kJQP7kiw5Fk');
    expect(job['video'], isTrue);

    // There is no yt-dlp off Android, so the job fails, saying why.
    while (server.youtube.jobs.any((j) => !j.isFinished)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(server.youtube.jobs.single.error, contains('Android'));
  });

  /// A raw request, for binary bodies and headers.
  Future<HttpClientResponse> get(String path, {String? pinHeader = pin, String? range}) async {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}$path'));
    if (pinHeader != null) req.headers.set('x-pin', pinHeader);
    if (range != null) req.headers.set('range', range);
    return req.close();
  }

  Future<List<int>> bytesOf(HttpClientResponse res) =>
      res.fold<List<int>>([], (all, chunk) => all..addAll(chunk));

  Future<Track> karaokeTrack(List<int> video) async {
    final dir = await Directory('${root.path}/download').create();
    Future<File> file(String name, List<int> data) => File('${dir.path}/$name').writeAsBytes(data);
    return library.importFiles(
      audio: await file('audio.m4a', [0]),
      video: await file('video.mp4', video),
      subtitles: {'en': await file('subs.en.vtt', utf8.encode('WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi\n'))},
      title: 'Karaoke',
      source: TrackSource.youtube,
    );
  }

  test('serves a song\'s video whole or by byte range, as a video element asks', () async {
    final video = List<int>.generate(1000, (i) => i % 256);
    final track = await karaokeTrack(video);
    final path = '/api/tracks/${track.id}/video';

    final whole = await get(path);
    expect(whole.statusCode, 200);
    expect(whole.headers.contentType?.mimeType, 'video/mp4');
    expect(whole.headers.value('accept-ranges'), 'bytes');
    expect(await bytesOf(whole), video);

    final middle = await get(path, range: 'bytes=10-19');
    expect(middle.statusCode, 206);
    expect(middle.headers.value('content-range'), 'bytes 10-19/1000');
    expect(await bytesOf(middle), video.sublist(10, 20));

    final open = await get(path, range: 'bytes=990-');
    expect(open.headers.value('content-range'), 'bytes 990-999/1000');
    expect(await bytesOf(open), video.sublist(990));

    final tail = await get(path, range: 'bytes=-5');
    expect(await bytesOf(tail), video.sublist(995));

    final past = await get(path, range: 'bytes=1000-');
    expect(past.statusCode, 416);
    expect(past.headers.value('content-range'), 'bytes */1000');
    await past.drain<void>();

    final odd = await get(path, range: 'bytes=0-1,5-6');
    expect(odd.statusCode, 200, reason: 'several ranges at once get the whole file');
    await odd.drain<void>();
  });

  test('media links can carry the PIN, but only for reading', () async {
    final track = await karaokeTrack([1, 2, 3]);

    final withPin = await get('/api/tracks/${track.id}/video?pin=$pin', pinHeader: null);
    expect(withPin.statusCode, 200);
    expect(await bytesOf(withPin), [1, 2, 3]);

    final wrong = await get('/api/tracks/${track.id}/video?pin=000000', pinHeader: null);
    expect(wrong.statusCode, 401);
    await wrong.drain<void>();

    final (status, _) = await call('DELETE', '/api/tracks/${track.id}?pin=$pin', pinHeader: null);
    expect(status, 401);
    expect(library.trackById(track.id), isNotNull);
  });

  test('serves subtitles, and lists video and lyrics with each song', () async {
    final track = await karaokeTrack([1]);
    final plain = await library.importStream(Stream.value([1]),
        extension: 'mp3', title: 'Plain', source: TrackSource.upload);

    final vtt = await get('/api/tracks/${track.id}/subtitles/en');
    expect(vtt.statusCode, 200);
    expect(vtt.headers.contentType?.mimeType, 'text/vtt');
    expect(utf8.decode(await bytesOf(vtt)), contains('Hi'));

    expect((await call('GET', '/api/tracks/${track.id}/subtitles/fr')).$1, 404);
    expect((await call('GET', '/api/tracks/${plain.id}/video')).$1, 404);
    expect((await call('GET', '/api/tracks/nope/video')).$1, 404);

    final (_, lib) = await call('GET', '/api/library');
    final songs = {for (final t in lib['tracks'] as List) t['title']: t};
    expect(songs['Karaoke']['hasVideo'], isTrue);
    expect(songs['Karaoke']['subtitles'], ['en']);
    expect(songs['Plain']['hasVideo'], isFalse);
    expect(songs['Plain']['subtitles'], isEmpty);
  });

  test('a browser dropping a video request midway does not hurt the server', () async {
    final track = await karaokeTrack(List<int>.filled(4 * 1024 * 1024, 7));
    final res = await get('/api/tracks/${track.id}/video');
    // Read a little, then hang up, like a video element that seeks elsewhere.
    await res.first;
    client.close(force: true);
    client = HttpClient();

    final again = await get('/api/tracks/${track.id}/video', range: 'bytes=0-3');
    expect(again.statusCode, 206);
    expect(await bytesOf(again), [7, 7, 7, 7]);
  });

  Future<(int, dynamic)> upload(String filename, List<int> data) {
    const boundary = 'videoboundary';
    return call('POST', '/api/upload',
        contentType: 'multipart/form-data; boundary=$boundary',
        raw: [
          ...utf8.encode('--$boundary\r\n'
              'Content-Disposition: form-data; name="file"; filename="$filename"\r\n'
              'Content-Type: application/octet-stream\r\n\r\n'),
          ...data,
          ...utf8.encode('\r\n--$boundary--\r\n'),
        ]);
  }

  test('an uploaded video becomes a song with video for the karaoke screen', () async {
    final media = FakeMediaTools();
    addTearDown(media.dispose);
    final video = List<int>.generate(2000, (i) => i % 251);

    final (status, result) = await upload('Party_Song.mkv', video);
    expect(status, 200);
    final added = (result['added'] as List).single;
    expect(added['title'], 'Party Song');
    expect(added['hasVideo'], isTrue);
    expect(added['durationMs'], 8000);

    final res = await get('/api/tracks/${added['id']}/video', range: 'bytes=0-');
    expect(res.statusCode, 206);
    expect(res.headers.contentType?.mimeType, 'video/x-matroska');
    expect(await bytesOf(res), video);
    final track = library.trackById(added['id'] as String)!;
    expect(await File(library.pathOf(track)).readAsBytes(), [9, 9], reason: 'the phone plays the copied sound');
  });

  test('a video without sound is refused, saying why', () async {
    final media = FakeMediaTools()..hasAudio = false;
    addTearDown(media.dispose);

    final (status, body) = await upload('silent.mp4', [1, 2, 3]);
    expect(status, 400);
    expect(body['error'], contains('no sound'));
    expect(library.tracks, isEmpty);
  });

  test('YouTube search needs words, and says when yt-dlp is missing', () async {
    final (status, body) = await call('GET', '/api/youtube/search?q=%20');
    expect(status, 400);
    expect(body['error'], contains('search'));

    // There is no yt-dlp off Android.
    final (missing, error) = await call('GET', '/api/youtube/search?q=despacito');
    expect(missing, 502);
    expect(error['error'], contains('Android'));
  });

  test('player commands validate input and explain an empty library', () async {
    final (status, body) = await call('POST', '/api/player/play', json: {});
    expect(status, 409);
    expect(body['error'], contains('no songs'));
    expect((await call('POST', '/api/player/repeat', json: {'mode': 'sideways'})).$1, 400);
    expect((await call('POST', '/api/player/volume', json: {'volume': 'loud'})).$1, 400);
  });

  test('malformed JSON is a 400, unknown API route is a 404', () async {
    final (status, _) = await call('POST', '/api/folders',
        contentType: 'application/json', raw: utf8.encode('{not json'));
    expect(status, 400);
    expect((await call('GET', '/api/does-not-exist')).$1, 404);
  });
}
