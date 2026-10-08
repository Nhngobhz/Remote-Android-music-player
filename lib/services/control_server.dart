import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_multipart/shelf_multipart.dart';
import 'package:shelf_router/shelf_router.dart';

import '../models/track.dart';
import 'audio_player_service.dart';
import 'library_service.dart';
import 'settings_service.dart';
import 'youtube_service.dart';
import 'ytdlp_service.dart';

/// HTTP server on the phone: serves the web controller page and a PIN-protected JSON API.
class ControlServer {
  ControlServer({
    required this.library,
    required this.player,
    required this.youtube,
    required this.settings,
    this.ytDlp,
  });

  static const firstPort = 8080;
  static const lastPort = 8090;
  static const _maxFailures = 5;
  static const _lockout = Duration(minutes: 1);
  static const _assets = {
    '': ('index.html', 'text/html; charset=utf-8'),
    'index.html': ('index.html', 'text/html; charset=utf-8'),
    'app.js': ('app.js', 'text/javascript; charset=utf-8'),
    'style.css': ('style.css', 'text/css; charset=utf-8'),
  };

  /// By file extension; mp4, m4v and mov all play as MP4.
  static const _videoTypes = {'webm': 'video/webm', 'mkv': 'video/x-matroska'};

  final LibraryService library;
  final PlayerHandler player;
  final YoutubeService youtube;
  final SettingsService settings;
  final YtDlpService? ytDlp;

  HttpServer? _server;
  final Map<String, List<DateTime>> _failures = {};
  final Map<String, (List<int>, String)> _assetCache = {};

  int? get port => _server?.port;

  Future<void> start({InternetAddress? address}) async {
    for (final entry in _assets.entries) {
      final data = await rootBundle.load('assets/control_web/${entry.value.$1}');
      _assetCache[entry.key] = (data.buffer.asUint8List(), entry.value.$2);
    }

    final handler = const Pipeline()
        .addMiddleware(_handleErrors)
        .addMiddleware(_requirePin)
        .addHandler(_buildRouter().call);

    for (var port = firstPort; port <= lastPort; port++) {
      try {
        _server = await shelf_io.serve(handler, address ?? InternetAddress.anyIPv4, port);
        return;
      } on SocketException {
        if (port == lastPort) rethrow;
      }
    }
  }

  Future<void> stop() async => _server?.close(force: true);

  Router _buildRouter() {
    final r = Router(notFoundHandler: _serveAsset);

    r.get('/api/ping', (Request _) => _json({'ok': true}));

    r.get('/api/status', (Request _) => _json({
          'player': player.status(),
          'jobs': youtube.jobs.map((j) => j.toJson()).toList(),
          'libraryVersion': library.version,
          'ytDlp': ytDlp?.toJson(),
        }));

    r.get('/api/library', (Request _) => _json({
          'version': library.version,
          'folders': library.folders
              .map((f) => {...f.toJson(), 'trackCount': library.tracksIn(f.id).length})
              .toList(),
          'tracks': library.tracks.map(_trackJson).toList(),
        }));

    r.post('/api/folders', (Request req) async {
      final body = await _body(req);
      return _json(library.createFolder(_string(body, 'name')).toJson(), status: 201);
    });

    r.patch('/api/folders/<id>', (Request req, String id) async {
      library.renameFolder(id, _string(await _body(req), 'name'));
      return _json({'ok': true});
    });

    r.delete('/api/folders/<id>', (Request _, String id) {
      library.deleteFolder(id);
      return _json({'ok': true});
    });

    r.patch('/api/tracks/<id>', (Request req, String id) async {
      final body = await _body(req);
      library.updateTrack(id,
          title: body['title'] as String?, folderId: body['folderId'] as String?);
      return _json({'ok': true});
    });

    r.delete('/api/tracks/<id>', (Request _, String id) async {
      await library.deleteTrack(id);
      return _json({'ok': true});
    });

    // The karaoke screen plays the video muted, in step with the audio on the phone.
    r.get('/api/tracks/<id>/video', (Request req, String id) {
      final track = library.trackById(id);
      final path = track == null ? null : library.videoPathOf(track);
      if (path == null) return _json({'error': 'This song has no video'}, status: 404);
      return _serveFile(req, File(path), _videoTypes[fileExtension(path)] ?? 'video/mp4');
    });

    r.get('/api/tracks/<id>/subtitles/<language>', (Request req, String id, String language) {
      final track = library.trackById(id);
      final path = track == null ? null : library.subtitlePathOf(track, language);
      if (path == null) return _json({'error': 'This song has no such subtitles'}, status: 404);
      return _serveFile(req, File(path), 'text/vtt; charset=utf-8');
    });

    // Music or video files. folderId is a query param because form fields may arrive
    // after the file parts.
    r.post('/api/upload', (Request req) async {
      final form = req.formData();
      if (form == null) return _json({'error': 'Expected a multipart/form-data upload'}, status: 400);
      final folderId = req.url.queryParameters['folderId'];
      final added = <Track>[];
      final rejected = <String>[];
      await for (final field in form.formData) {
        final filename = field.filename;
        if (filename == null) {
          await field.part.drain<void>();
          continue;
        }
        final ext = fileExtension(filename);
        if (!LibraryService.audioExtensions.contains(ext)) {
          rejected.add(filename);
          await field.part.drain<void>();
          continue;
        }
        added.add(await library.importStream(
          field.part,
          extension: ext,
          title: titleFromFileName(filename),
          folderId: folderId,
          source: TrackSource.upload,
        ));
      }
      return _json({'added': added.map(_trackJson).toList(), 'rejected': rejected});
    });

    r.post('/api/youtube', (Request req) async {
      final body = await _body(req);
      final folderId = body['folderId'] as String?;
      final jobs = await youtube.enqueue(_string(body, 'url'),
          folderId: (folderId == null || folderId.isEmpty) ? null : folderId,
          video: body['video'] == true);
      return _json({'jobs': jobs.map((j) => j.toJson()).toList()}, status: 202);
    });

    r.post('/api/jobs/<id>/retry', (Request _, String id) {
      youtube.retry(id);
      return _json({'ok': true});
    });

    r.post('/api/jobs/clear', (Request _) {
      youtube.clearFinished();
      return _json({'ok': true});
    });

    r.post('/api/ytdlp/update', (Request _) async {
      final ytDlp = this.ytDlp;
      if (ytDlp == null || !YtDlpService.isSupported) {
        throw StateError('yt-dlp is not available on this device');
      }
      final updated = await ytDlp.update();
      return _json({'updated': updated, ...ytDlp.toJson()});
    });

    r.post('/api/player/play', (Request req) async {
      final body = await _body(req);
      final trackId = body['trackId'] as String?;
      var folderId = body['folderId'] as String?;
      if (trackId != null && folderId == null) {
        folderId = library.trackById(trackId)?.folderId ?? (throw ArgumentError('Track not found'));
      }
      if (folderId != null) {
        await player.playFolder(folderId == 'all' ? null : folderId,
            startTrackId: trackId, shuffle: body['shuffle'] as bool?);
      } else {
        await player.play();
      }
      return _json(player.status());
    });

    r.post('/api/player/pause', (Request _) async {
      await player.pause();
      return _json(player.status());
    });

    r.post('/api/player/next', (Request _) async {
      await player.skipToNext();
      return _json(player.status());
    });

    r.post('/api/player/previous', (Request _) async {
      await player.skipToPrevious();
      return _json(player.status());
    });

    r.post('/api/player/shuffle', (Request req) async {
      await player.setShuffle((await _body(req))['enabled'] == true);
      return _json(player.status());
    });

    r.post('/api/player/repeat', (Request req) async {
      final mode = PlaybackRepeat.values.asNameMap()[_string(await _body(req), 'mode')];
      if (mode == null) throw ArgumentError('mode must be off, all or one');
      await player.setRepeat(mode);
      return _json(player.status());
    });

    r.post('/api/player/seek', (Request req) async {
      final ms = (await _body(req))['positionMs'];
      if (ms is! num) throw ArgumentError('positionMs must be a number');
      await player.seek(Duration(milliseconds: ms.toInt()));
      return _json(player.status());
    });

    r.post('/api/player/volume', (Request req) async {
      final volume = (await _body(req))['volume'];
      if (volume is! num) throw ArgumentError('volume must be a number between 0 and 1');
      await player.setVolume(volume.toDouble());
      return _json(player.status());
    });

    return r;
  }

  Response _serveAsset(Request req) {
    final asset = _assetCache[req.url.path];
    if (req.method != 'GET' || asset == null) {
      return _json({'error': 'Not found'}, status: 404);
    }
    return Response.ok(asset.$1, headers: {
      'content-type': asset.$2,
      'cache-control': 'no-cache',
    });
  }

  /// Serves a file, or the byte range the browser asks for: a video element needs ranges
  /// to seek, and asks for one from the start.
  static Future<Response> _serveFile(Request req, File file, String contentType) async {
    final length = await file.length();
    final headers = {
      'content-type': contentType,
      'accept-ranges': 'bytes',
      // A track's files never change, so a revisited video or seek can reuse what's loaded.
      'cache-control': 'private, max-age=86400',
    };
    // One range only (bytes=start-end, start- or -suffix); anything else gets the whole file.
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(req.headers['range']?.trim() ?? '');
    final from = match?.group(1) ?? '';
    final to = match?.group(2) ?? '';
    if (match == null || (from.isEmpty && to.isEmpty)) {
      return Response.ok(file.openRead(), headers: {...headers, 'content-length': '$length'});
    }
    int start;
    int end;
    if (from.isEmpty) {
      start = length - int.parse(to);
      if (start < 0) start = 0;
      end = length - 1;
    } else {
      start = int.parse(from);
      end = to.isEmpty ? length - 1 : int.parse(to);
      if (end >= length) end = length - 1;
    }
    if (start >= length || start > end) {
      return Response(HttpStatus.requestedRangeNotSatisfiable,
          headers: {...headers, 'content-range': 'bytes */$length'});
    }
    return Response(HttpStatus.partialContent, body: file.openRead(start, end + 1), headers: {
      ...headers,
      'content-range': 'bytes $start-$end/$length',
      'content-length': '${end - start + 1}',
    });
  }

  Handler _requirePin(Handler inner) => (Request req) {
        if (!req.url.path.startsWith('api/')) return inner(req);

        final ip = (req.context['shelf.io.connection_info'] as HttpConnectionInfo?)
                ?.remoteAddress
                .address ??
            'unknown';
        final now = DateTime.now();
        final recent = (_failures[ip] ?? [])..removeWhere((t) => now.difference(t) > _lockout);
        if (recent.length >= _maxFailures) {
          return _json({'error': 'Too many wrong PIN attempts, wait a minute'}, status: 429);
        }
        // Video and subtitle elements can't send headers, so reads may put the PIN in the URL.
        final readOnly = req.method == 'GET' || req.method == 'HEAD';
        final pin = req.headers['x-pin'] ?? (readOnly ? req.url.queryParameters['pin'] : null);
        if (pin != settings.pin) {
          _failures[ip] = recent..add(now);
          return _json({'error': 'Wrong PIN'}, status: 401);
        }
        _failures.remove(ip);
        return inner(req);
      };

  Handler _handleErrors(Handler inner) => (Request req) async {
        try {
          return await inner(req);
        } on ArgumentError catch (e) {
          return _json({'error': '${e.message}'}, status: 400);
        } on FormatException catch (e) {
          return _json({'error': e.message}, status: 400);
        } on StateError catch (e) {
          return _json({'error': e.message}, status: 409);
        } on YtDlpException catch (e) {
          return _json({'error': e.message}, status: 502);
        } on FileSystemException catch (e) {
          debugPrint('Storage error for ${req.method} ${req.url}: $e');
          return _json({'error': 'The phone could not use its storage (is it full?)'}, status: 500);
        } catch (e) {
          return _json({'error': 'Something went wrong on the phone: $e'}, status: 500);
        }
      };

  Map<String, dynamic> _trackJson(Track t) => {
        'id': t.id,
        'title': t.title,
        'artist': t.artist,
        'folderId': t.folderId,
        'durationMs': t.durationMs,
        'hasVideo': t.hasVideo,
        'subtitles': t.subtitleFileNames.keys.toList(),
        'source': t.source.name,
        'sourceUrl': t.sourceUrl,
        'addedAt': t.addedAt.toIso8601String(),
      };

  static Future<Map<String, dynamic>> _body(Request req) async {
    final text = await req.readAsString();
    if (text.trim().isEmpty) return {};
    final data = jsonDecode(text);
    if (data is! Map<String, dynamic>) throw const FormatException('Expected a JSON object');
    return data;
  }

  static String _string(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is! String || value.trim().isEmpty) throw ArgumentError('$key is required');
    return value;
  }

  static Response _json(Object? data, {int status = 200}) => Response(status,
      body: jsonEncode(data), headers: {'content-type': 'application/json; charset=utf-8'});
}
