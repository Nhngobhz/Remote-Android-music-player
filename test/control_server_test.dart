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
import 'package:shared_preferences/shared_preferences.dart';

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
      youtube: YoutubeService(library),
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
