import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'library_service.dart';

/// yt-dlp running on the phone through the youtubedl-android library (YtDlpBridge.kt).
/// It is slower to start than youtube_explode_dart, but it solves YouTube's JavaScript
/// challenges and updates itself, so it gets the videos YouTube only serves in part to
/// youtube_explode's clients (often official music-label uploads).
class YtDlpService extends ChangeNotifier {
  /// [workRoot] holds one folder per download until its file is imported.
  YtDlpService({this._workRoot}) {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel('music_contoller/ytdlp');
  static const _updateInterval = Duration(days: 1);
  static const _maxErrorLength = 300;

  /// yt-dlp prints nothing while it solves YouTube's challenges, which can take a while
  /// with QuickJS on a phone, so this is much longer than youtube_explode's stall timeout.
  static const _stallTimeout = Duration(minutes: 3);

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  Directory? _workRoot;
  final Map<String, void Function(double percent)> _progressListeners = {};
  String? _version;
  String? _updateError;
  Future<bool>? _update;
  Timer? _updateTimer;

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

  /// Downloads the best audio-only stream of [url]. [onProgress] gets 0–1 once the
  /// transfer starts. Call [YtDlpDownload.delete] after importing the file.
  Future<YtDlpDownload> download(String url, {void Function(double fraction)? onProgress}) async {
    // Unique per call, so a late cancel of an earlier attempt can't hit a retry.
    final runId = '${DateTime.now().microsecondsSinceEpoch}';
    final dir = await Directory('${(await _root()).path}/$runId').create(recursive: true);

    Timer? watchdog;
    var stalled = false;
    void resetWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(_stallTimeout, () {
        stalled = true;
        _channel.invokeMethod('cancel', {'id': runId});
      });
    }

    _progressListeners[runId] = (percent) {
      resetWatchdog();
      if (percent >= 0) onProgress?.call((percent / 100).clamp(0.0, 1.0));
    };
    resetWatchdog();
    try {
      await _channel.invokeMethod('download', {'id': runId, 'url': url, 'dir': dir.path});
      return await YtDlpDownload._read(dir);
    } catch (e) {
      await dir.delete(recursive: true).catchError((_) => dir);
      if (e is! PlatformException) rethrow;
      if (stalled || e.code == 'CANCELED') throw const YtDlpStalled();
      debugPrint('yt-dlp failed for $url:\n${e.message}');
      throw YtDlpException(errorMessage(e.message));
    } finally {
      watchdog?.cancel();
      _progressListeners.remove(runId);
    }
  }

  Future<Directory> _root() async =>
      _workRoot ??= Directory('${(await getTemporaryDirectory()).path}/ytdlp');

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'progress') return;
    final args = call.arguments as Map;
    _progressListeners[args['id']]?.call((args['percent'] as num).toDouble());
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

/// An audio file yt-dlp saved, with the details it reported about the video.
class YtDlpDownload {
  YtDlpDownload._(this.file, {this.title, this.artist, this.durationMs});

  final File file;
  final String? title;
  final String? artist;
  final int? durationMs;

  String get extension => fileExtension(file.path);

  /// Removes the file and the folder it was downloaded into.
  Future<void> delete() => file.parent.delete(recursive: true);

  static Future<YtDlpDownload> _read(Directory dir) async {
    final files = (await dir.list().toList()).whereType<File>();
    final audio = files
        .where((f) => LibraryService.audioExtensions.contains(fileExtension(f.path)))
        .firstOrNull;
    if (audio == null) throw const YtDlpException('yt-dlp finished without saving an audio file');

    // Written by --print-to-file once the download is done; missing details are fine.
    var info = <String, dynamic>{};
    final infoFile = File('${dir.path}/info.json');
    try {
      final firstLine = (await infoFile.readAsLines()).first;
      info = jsonDecode(firstLine) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('No usable yt-dlp info for ${audio.path}: $e');
    }
    final duration = info['duration'];
    return YtDlpDownload._(
      audio,
      title: info['title'] as String?,
      artist: (info['channel'] ?? info['uploader']) as String?,
      durationMs: duration is num ? (duration * 1000).round() : null,
    );
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
