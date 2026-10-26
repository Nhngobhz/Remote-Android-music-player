import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'library_service.dart';

/// yt-dlp running on the phone through the youtubedl-android library (YtDlpBridge.kt).
/// It solves YouTube's JavaScript challenges and updates itself, so it keeps up when
/// YouTube changes things.
class YtDlpService extends ChangeNotifier {
  /// [workRoot] holds one folder per download until its files are imported.
  YtDlpService({this._workRoot}) {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel('music_contoller/ytdlp');
  static const _updateInterval = Duration(days: 1);
  static const _maxErrorLength = 300;

  /// yt-dlp prints nothing while it solves YouTube's challenges, which can take a while
  /// with QuickJS on a phone.
  static const _stallTimeout = Duration(minutes: 3);

  /// AAC plays everywhere; any other audio-only stream is the fallback.
  static const _audioFormat = 'bestaudio[ext=m4a]/bestaudio';

  /// How to rank video streams: the sharpest up to 1080p first, then 30 fps over 60 (which
  /// would only double the size), then H.264, which every browser decodes cheaply. A sort
  /// rather than a filter, so a video that only has 60 fps above 480p still comes in 1080p.
  static const _videoSort = 'res:1080,fps:30,+vcodec:avc';

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  Directory? _workRoot;
  final Map<String, void Function(String line)> _lineListeners = {};
  String? _version;
  String? _updateError;
  Future<bool>? _update;
  Timer? _updateTimer;
  int _runCount = 0;

  String? get version => _version;
  bool get updating => _update != null;

  Map<String, dynamic> toJson() => {
        'version': _version,
        'updating': updating,
        'updateError': _updateError,
      };

  /// Unpacks yt-dlp on first run, then keeps it up to date in the background.
  Future<void> start() async {
    if (!isSupported) return;
    // Leftovers from downloads cut off when the app was killed.
    final root = await _root();
    if (await root.exists()) await root.delete(recursive: true);
    try {
      _version = await _channel.invokeMethod<String>('init');
    } on PlatformException catch (e) {
      debugPrint('yt-dlp failed to start: ${e.message}');
    }
    notifyListeners();
    await _autoUpdate();
    _updateTimer = Timer.periodic(_updateInterval, (_) => _autoUpdate());
  }

  /// Installs the newest yt-dlp release if there is one, and returns whether it did.
  Future<bool> update() {
    final running = _update;
    if (running != null) return running;
    _updateError = null;
    final future = _update = _runUpdate();
    notifyListeners();
    return future;
  }

  Future<bool> _runUpdate() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('update');
      _version = result?['version'] as String? ?? _version;
      return result?['updated'] == true;
    } on PlatformException catch (e) {
      _updateError = _truncate(e.message ?? 'unknown error');
      throw StateError('Could not update yt-dlp: $_updateError');
    } finally {
      _update = null;
      notifyListeners();
    }
  }

  Future<void> _autoUpdate() =>
      update().then((_) {}, onError: (Object e) => debugPrint('yt-dlp update check failed: $e'));

  /// Downloads the best audio-only stream of [url] for the phone to play. With [video],
  /// it also saves a video-only stream and the uploader's subtitles for the karaoke screen.
  /// [onProgress] gets 0–1 once the transfer starts. Call [YtDlpDownload.delete] after
  /// importing the files.
  Future<YtDlpDownload> download(
    String url, {
    bool video = false,
    void Function(double fraction)? onProgress,
  }) async {
    final runId = _newRunId();
    final dir = await Directory('${(await _root()).path}/$runId').create(recursive: true);
    final progress = YtDlpProgress(video: video);
    try {
      await _run(runId, url, downloadOptions(dir.path, video: video, cacheDir: await _cacheDir()),
          onLine: (line) {
        final fraction = progress.onLine(line);
        if (fraction != null) onProgress?.call(fraction);
      });
      return await YtDlpDownload._read(dir);
    } catch (_) {
      await dir.delete(recursive: true).catchError((_) => dir);
      rethrow;
    }
  }

  /// The videos of a playlist link, at most [limit] of them, without looking each one up.
  Future<YtDlpPlaylist> listPlaylist(String url, {required int limit}) async {
    final out = await _run(_newRunId(), url, playlistOptions(limit: limit, cacheDir: await _cacheDir()));
    return YtDlpPlaylist.parse(out);
  }

  /// The first [limit] videos YouTube finds for [query], best match first. yt-dlp lists
  /// search results the same way as a playlist.
  Future<List<YtDlpVideo>> search(String query, {required int limit}) async =>
      (await listPlaylist('ytsearch$limit:$query', limit: limit)).videos;

  /// The yt-dlp options for a download into [dir]. There is no ffmpeg on the phone to
  /// merge streams, so audio and video are saved as separate files: the phone plays the
  /// audio and the web page shows the video in step with it.
  @visibleForTesting
  static List<String> downloadOptions(String dir, {required bool video, required String cacheDir}) => [
        '--no-playlist',
        '-f', video ? '$_audioFormat,bestvideo' : _audioFormat,
        if (video) ...['-S', _videoSort],
        // The audio stream has no height, so this saves audio.m4a and video.mp4.
        '-o', '$dir/%(height&video|audio)s.%(ext)s',
        '-o', 'subtitle:$dir/subs.%(ext)s',
        if (video) ...[
          // Only the uploader's subtitles (often lyrics). YouTube's automatic captions are
          // poor for songs and come in a hundred machine-translated languages.
          '--write-subs', '--sub-langs', 'all,-live_chat', '--sub-format', 'vtt',
          // Makes a subtitle that fails to download a warning instead of failing the song.
          '--ignore-errors',
        ],
        // Also keeps the subtitles from being fetched a second time for the video stream.
        '--no-overwrites',
        // No ffmpeg is bundled, and the raw streams play fine without a fixup.
        '--fixup', 'never',
        '--newline',
        '--progress-delta', '0.5',
        '--socket-timeout', '30',
        // Keeps YouTube's player code prepared between runs, which is slow with QuickJS.
        '--cache-dir', cacheDir,
        '--print-to-file', 'after_move:%(.{title,uploader,channel,duration})j', '$dir/info.json',
      ];

  @visibleForTesting
  static List<String> playlistOptions({required int limit, required String cacheDir}) => [
        '--flat-playlist',
        '--dump-single-json',
        '--playlist-items', '1:$limit',
        '--socket-timeout', '30',
        '--cache-dir', cacheDir,
      ];

  String _newRunId() => '${DateTime.now().microsecondsSinceEpoch}-${_runCount++}';

  /// Runs yt-dlp and returns what it printed. A run that prints nothing for
  /// [_stallTimeout] is canceled. The run id is unique per call, so a late cancel of an
  /// earlier attempt can't hit a retry.
  Future<String> _run(String runId, String url, List<String> options,
      {void Function(String line)? onLine}) async {
    Timer? watchdog;
    var stalled = false;
    void resetWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(_stallTimeout, () {
        stalled = true;
        _channel.invokeMethod('cancel', {'id': runId});
      });
    }

    _lineListeners[runId] = (line) {
      resetWatchdog();
      onLine?.call(line);
    };
    resetWatchdog();
    try {
      return await _channel.invokeMethod<String>('run', {
            'id': runId,
            'url': url,
            'options': options,
            'reportLines': onLine != null,
          }) ??
          '';
    } on MissingPluginException {
      throw const YtDlpException('Downloads only work in the Android app');
    } on PlatformException catch (e) {
      if (stalled || e.code == 'CANCELED') throw const YtDlpStalled();
      debugPrint('yt-dlp failed for $url:\n${e.message}');
      throw YtDlpException(errorMessage(e.message));
    } finally {
      watchdog?.cancel();
      _lineListeners.remove(runId);
    }
  }

  Future<Directory> _root() async =>
      _workRoot ??= Directory('${(await getTemporaryDirectory()).path}/ytdlp');

  /// Next to the download folders, but not cleared on start.
  Future<String> _cacheDir() async => '${(await _root()).parent.path}/ytdlp-cache';

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'line') return;
    final args = call.arguments as Map;
    _lineListeners[args['id']]?.call(args['line'] as String);
  }

  /// yt-dlp's stderr also carries warnings; its last ERROR line is the one that matters.
  @visibleForTesting
  static String errorMessage(String? stderr) {
    final lines = const LineSplitter()
        .convert(stderr ?? '')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return 'yt-dlp failed without saying why';
    final error = lines.lastWhere((l) => l.startsWith('ERROR:'), orElse: () => lines.last);
    // "ERROR: [youtube] kJQP7kiw5Fk: Video unavailable" -> "Video unavailable"
    return _truncate(error.replaceFirst(RegExp(r'^ERROR:\s*(\[[^\]]+\]\s*[\w-]+:\s*)?'), ''));
  }

  static String _truncate(String text) =>
      text.length > _maxErrorLength ? '${text.substring(0, _maxErrorLength)}…' : text;

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }
}

/// Turns yt-dlp's output into overall progress. The subtitles come first, then the audio
/// stream, then the video stream, which is usually about nine tenths of the bytes.
@visibleForTesting
class YtDlpProgress {
  YtDlpProgress({required bool video}) : _audioShare = video ? 0.1 : 1.0;

  static final _destination = RegExp(r'^\[download\] Destination: (.+)$');
  static final _percent = RegExp(r'^\[download\]\s+(\d+(?:\.\d+)?)%');

  final double _audioShare;

  /// The stream being downloaded: 'audio', 'video', or null for subtitles.
  String? _stream;

  /// The overall fraction done, or null when [line] isn't about the audio or video stream.
  double? onLine(String line) {
    final destination = _destination.firstMatch(line);
    if (destination != null) {
      final name = destination.group(1)!.split(RegExp(r'[/\\]')).last;
      _stream = name.endsWith('.vtt') ? null : name.split('.').first;
      return null;
    }
    final percent = _percent.firstMatch(line);
    if (percent == null) return null;
    final fraction = (double.parse(percent.group(1)!) / 100).clamp(0.0, 1.0);
    return switch (_stream) {
      'audio' => fraction * _audioShare,
      'video' => _audioShare + fraction * (1 - _audioShare),
      _ => null,
    };
  }
}

/// Files yt-dlp saved, with the details it reported about the video.
class YtDlpDownload {
  YtDlpDownload._(this._dir, this.audio,
      {this.video, this.subtitles = const {}, this.title, this.artist, this.durationMs});

  final Directory _dir;
  final File audio;

  /// The video-only stream, when one was asked for and YouTube had one.
  final File? video;

  /// WebVTT files by language code.
  final Map<String, File> subtitles;
  final String? title;
  final String? artist;
  final int? durationMs;

  /// Removes the download folder and anything still in it.
  Future<void> delete() async {
    if (await _dir.exists()) await _dir.delete(recursive: true);
  }

  static Future<YtDlpDownload> _read(Directory dir) async {
    File? audio;
    File? video;
    final subtitles = <String, File>{};
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      // audio.m4a, video.mp4 and subs.<language>.vtt; anything else is a leftover.
      final parts = entry.path.split(RegExp(r'[/\\]')).last.split('.');
      if (parts.length == 2 && parts[0] == 'audio' && LibraryService.audioExtensions.contains(parts[1])) {
        audio = entry;
      } else if (parts.length == 2 && parts[0] == 'video' && LibraryService.videoExtensions.contains(parts[1])) {
        video = entry;
      } else if (parts.length == 3 && parts[0] == 'subs' && parts[2] == 'vtt') {
        subtitles[parts[1]] = entry;
      }
    }
    if (audio == null) throw const YtDlpException('yt-dlp finished without saving an audio file');

    // Written by --print-to-file once a stream is done; missing details are fine.
    var info = <String, dynamic>{};
    try {
      final firstLine = (await File('${dir.path}/info.json').readAsLines()).first;
      info = jsonDecode(firstLine) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('No usable yt-dlp info for ${audio.path}: $e');
    }
    final duration = info['duration'];
    return YtDlpDownload._(
      dir,
      audio,
      video: video,
      subtitles: subtitles,
      title: info['title'] as String?,
      artist: (info['channel'] ?? info['uploader']) as String?,
      durationMs: duration is num ? (duration * 1000).round() : null,
    );
  }
}

/// A video in a playlist or in search results.
class YtDlpVideo {
  const YtDlpVideo({required this.url, this.id, this.title, this.channel, this.durationMs});

  final String url;
  final String? id;
  final String? title;
  final String? channel;
  final int? durationMs;

  Map<String, dynamic> toJson() =>
      {'id': id, 'url': url, 'title': title, 'channel': channel, 'durationMs': durationMs};
}

class YtDlpPlaylist {
  YtDlpPlaylist({required this.title, required this.videos});

  final String? title;
  final List<YtDlpVideo> videos;

  /// Reads yt-dlp's --dump-single-json output. Private and deleted videos still show up
  /// in playlists, but can't be downloaded, and neither can a live or upcoming stream.
  static YtDlpPlaylist parse(String output) {
    final json = const LineSplitter().convert(output).lastWhere((l) => l.startsWith('{'),
        orElse: () => throw const YtDlpException('yt-dlp did not list the playlist'));
    final data = jsonDecode(json) as Map<String, dynamic>;
    final videos = <YtDlpVideo>[];
    for (final entry in (data['entries'] as List? ?? const []).whereType<Map<String, dynamic>>()) {
      final title = entry['title'] as String?;
      if (title == '[Private video]' || title == '[Deleted video]') continue;
      if (entry['live_status'] == 'is_live' || entry['live_status'] == 'is_upcoming') continue;
      final id = entry['id'] as String?;
      final url = id != null ? 'https://www.youtube.com/watch?v=$id' : entry['url'] as String?;
      if (url == null) continue;
      final duration = entry['duration'];
      videos.add(YtDlpVideo(
        url: url,
        id: id,
        title: title,
        channel: (entry['channel'] ?? entry['uploader']) as String?,
        durationMs: duration is num ? (duration * 1000).round() : null,
      ));
    }
    return YtDlpPlaylist(title: data['title'] as String?, videos: videos);
  }
}

class YtDlpException implements Exception {
  const YtDlpException(this.message);

  final String message;

  @override
  String toString() => 'YtDlpException: $message';
}

class YtDlpStalled implements Exception {
  const YtDlpStalled();
}
