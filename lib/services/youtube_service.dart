import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/track.dart';
import 'library_service.dart';
import 'ytdlp_service.dart';

enum JobStatus { queued, fetching, downloading, done, failed }

class DownloadJob {
  DownloadJob({required this.id, required this.url, required this.folderId, this.title});

  final String id;
  final String url;
  final String? folderId;
  String? title;
  JobStatus status = JobStatus.queued;
  double progress = 0;
  String? error;

  bool get isFinished => status == JobStatus.done || status == JobStatus.failed;

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'title': title,
        'status': status.name,
        'progress': progress,
        'error': error,
      };
}

/// Downloads audio from YouTube links on the phone, one job at a time
/// (YouTube tends to block parallel stream downloads from the same client).
/// youtube_explode_dart is tried first because it is fast; yt-dlp takes over the
/// videos it can't get.
class YoutubeService extends ChangeNotifier {
  YoutubeService(this._library, {this._ytDlp});

  static const _maxPlaylistVideos = 300;
  static const _keepFinishedJobs = 30;
  static const _uuid = Uuid();

  /// Tried in order until YouTube will serve a video's whole audio stream. For some
  /// videos (often official music-label uploads) a client only gets the first ~1 MB,
  /// and the library then retries forever without delivering any data.
  static final _clients = [
    YoutubeApiClient.androidSdkless, // the library's default
    YoutubeApiClient.ios,
    YoutubeApiClient.androidVr,
  ];

  /// A download that delivers no data for this long is abandoned so the queue moves on.
  static const _stallTimeout = Duration(seconds: 30);

  final LibraryService _library;
  final YtDlpService? _ytDlp;
  final List<DownloadJob> _jobs = [];
  bool _running = false;
  DateTime _lastProgressNotify = DateTime(0);

  List<DownloadJob> get jobs => List.unmodifiable(_jobs);

  /// Queues a video, or every video of a playlist link. When [folderId] is null,
  /// playlists go into a folder named after the playlist and single videos go to Unsorted.
  Future<List<DownloadJob>> enqueue(String url, {String? folderId}) async {
    final link = url.trim();
    final videoId = VideoId.parseVideoId(link);
    final playlistId = PlaylistId.parsePlaylistId(link);

    final List<DownloadJob> created;
    if (videoId != null) {
      created = [DownloadJob(id: _uuid.v4(), url: 'https://www.youtube.com/watch?v=$videoId', folderId: folderId)];
    } else if (playlistId != null) {
      created = await _expandPlaylist(playlistId, folderId);
    } else {
      throw const FormatException('That is not a YouTube video or playlist link');
    }

    _jobs.addAll(created);
    _pruneFinished();
    notifyListeners();
    _pump();
    return created;
  }

  void retry(String jobId) {
    final job = _jobs.where((j) => j.id == jobId).firstOrNull;
    if (job == null) throw ArgumentError('Download not found');
    if (job.status != JobStatus.failed) return;
    job
      ..status = JobStatus.queued
      ..progress = 0
      ..error = null;
    notifyListeners();
    _pump();
  }

  void clearFinished() {
    _jobs.removeWhere((j) => j.isFinished);
    notifyListeners();
  }

  Future<List<DownloadJob>> _expandPlaylist(String playlistId, String? folderId) async {
    final yt = YoutubeExplode();
    try {
      final playlist = await yt.playlists.get(playlistId);
      final targetFolderId = folderId ??
          (_library.folderByName(playlist.title) ?? _library.createFolder(playlist.title)).id;
      final videos = await yt.playlists.getVideos(playlistId).take(_maxPlaylistVideos).toList();
      if (videos.isEmpty) throw const FormatException('That playlist has no videos');
      return [
        for (final v in videos)
          DownloadJob(
            id: _uuid.v4(),
            url: 'https://www.youtube.com/watch?v=${v.id.value}',
            folderId: targetFolderId,
            title: v.title,
          ),
      ];
    } finally {
      yt.close();
    }
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final job = _jobs.where((j) => j.status == JobStatus.queued).firstOrNull;
        if (job == null) break;
        await _process(job);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _process(DownloadJob job) async {
    try {
      try {
        await _downloadWithExplode(job);
      } catch (e) {
        final ytDlp = _ytDlp;
        if (ytDlp == null || !YtDlpService.isSupported || !_worthTryingYtDlp(e)) rethrow;
        debugPrint('youtube_explode could not get ${job.url} ($e), trying yt-dlp');
        try {
          await _downloadWithYtDlp(job, ytDlp);
        } on YtDlpException catch (ytDlpError) {
          // YouTube now and then refuses a stream URL it serves fine on the next try.
          if (!ytDlpError.message.contains('HTTP Error 403')) rethrow;
          debugPrint('yt-dlp got a 403 for ${job.url}, trying once more');
          await _downloadWithYtDlp(job, ytDlp);
        }
      }
      job
        ..status = JobStatus.done
        ..progress = 1;
    } catch (e, s) {
      debugPrint('YouTube download failed for ${job.url}: $e\n$s');
      job
        ..status = JobStatus.failed
        ..error = _describeError(e);
    } finally {
      notifyListeners();
    }
  }

  /// yt-dlp can't help while YouTube rate-limits this IP, when the phone is offline,
  /// or when the video has to be bought.
  static bool _worthTryingYtDlp(Object e) =>
      e is! RequestLimitExceededException &&
      e is! SocketException &&
      e is! VideoRequiresPurchaseException;

  Future<void> _downloadWithExplode(DownloadJob job) async {
    final yt = YoutubeExplode();
    try {
      job.status = JobStatus.fetching;
      notifyListeners();

      final video = await yt.videos.get(job.url);
      job.title = video.title;
      final audio = await _findFullAudio(yt, video.id);
      final total = audio.size.totalBytes;

      job.status = JobStatus.downloading;
      notifyListeners();

      var received = 0;
      final stream = yt.videos.streams.get(audio).timeout(_stallTimeout, onTimeout: (sink) {
        // Closing the client ends the library's internal retry loop, which otherwise
        // keeps the stream from ever finishing its cancel.
        yt.close();
        sink
          ..addError(const _DownloadStalled())
          ..close();
      }).map((chunk) {
        received += chunk.length;
        if (total > 0) job.progress = (received / total).clamp(0.0, 1.0);
        _notifyProgress();
        return chunk;
      });

      await _library.importStream(
        stream,
        extension: audio.container == StreamContainer.mp4 ? 'm4a' : audio.container.name,
        title: video.title,
        artist: video.author,
        durationMs: video.duration?.inMilliseconds,
        folderId: job.folderId,
        source: TrackSource.youtube,
        sourceUrl: job.url,
      );
    } finally {
      yt.close();
    }
  }

  Future<void> _downloadWithYtDlp(DownloadJob job, YtDlpService ytDlp) async {
    job
      ..status = JobStatus.fetching
      ..progress = 0;
    notifyListeners();

    final download = await ytDlp.download(job.url, onProgress: (fraction) {
      job
        ..status = JobStatus.downloading
        ..progress = fraction;
      _notifyProgress();
    });
    try {
      job.title = download.title ?? job.title;
      await _library.importStream(
        download.file.openRead(),
        extension: download.extension,
        title: job.title ?? 'Untitled',
        artist: download.artist,
        durationMs: download.durationMs,
        folderId: job.folderId,
        source: TrackSource.youtube,
        sourceUrl: job.url,
      );
    } finally {
      await download.delete();
    }
  }

  /// Picks the best audio stream from the first client that YouTube will serve in full.
  Future<AudioOnlyStreamInfo> _findFullAudio(YoutubeExplode yt, VideoId id) async {
    Object? firstError;
    var blocked = false;
    for (final client in _clients) {
      try {
        final audio = _pickAudio(await yt.videos.streams.getManifest(id, ytClients: [client]));
        if (await _servesWholeStream(audio)) return audio;
        blocked = true;
      } on RequestLimitExceededException {
        rethrow; // More clients would only make the rate limit worse.
      } on SocketException {
        rethrow;
      } catch (e) {
        firstError ??= e;
      }
    }
    throw blocked ? const _DownloadBlocked() : firstError!;
  }

  /// Asks for just the last byte. YouTube refuses it (403) when it would cut the
  /// download off partway, so a blocked client is caught in a fraction of a second.
  static Future<bool> _servesWholeStream(AudioOnlyStreamInfo audio) async {
    final last = audio.size.totalBytes - 1;
    if (last < 0) return true; // Unknown size: leave it to the stall timeout.
    // Same range style as the library: a header for ANDROID urls, a query param otherwise.
    final byHeader = audio.url.queryParameters['c'] == 'ANDROID';
    final url = byHeader
        ? audio.url
        : audio.url.replace(queryParameters: {...audio.url.queryParameters, 'range': '$last-$last'});
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(url);
      req.headers.set(HttpHeaders.userAgentHeader, YoutubeHttpClient.defaultHeaders['user-agent']!);
      if (byHeader) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$last-$last');
      final res = await req.close().timeout(const Duration(seconds: 15));
      await res.drain<void>();
      return res.statusCode == HttpStatus.partialContent || res.statusCode == HttpStatus.ok;
    } finally {
      client.close(force: true);
    }
  }

  /// Prefers AAC/mp4 audio because it plays everywhere, including if the file is copied off the phone.
  AudioOnlyStreamInfo _pickAudio(StreamManifest manifest) {
    final audio = manifest.audioOnly;
    if (audio.isEmpty) throw const FormatException('No audio stream available for this video');
    final mp4 = audio.where((s) => s.container == StreamContainer.mp4);
    return mp4.isNotEmpty ? mp4.withHighestBitrate() : audio.withHighestBitrate();
  }

  void _notifyProgress() {
    final now = DateTime.now();
    if (now.difference(_lastProgressNotify) < const Duration(milliseconds: 300)) return;
    _lastProgressNotify = now;
    notifyListeners();
  }

  void _pruneFinished() {
    final finished = _jobs.where((j) => j.isFinished).toList();
    if (finished.length <= _keepFinishedJobs) return;
    _jobs.removeWhere(finished.take(finished.length - _keepFinishedJobs).toSet().contains);
  }

  String _describeError(Object e) => switch (e) {
        _DownloadBlocked() => 'YouTube blocks downloading this video (common for official '
            'music-label uploads). Try another upload of the song, like a lyric video',
        _DownloadStalled() => 'The download stopped receiving data, try again',
        YtDlpStalled() => 'yt-dlp stopped making progress, try again',
        YtDlpException(:final message) => 'Download failed: $message',
        VideoRequiresPurchaseException() => 'This video requires a purchase',
        VideoUnavailableException() => 'This video is unavailable',
        VideoUnplayableException() => 'This video can\'t be downloaded (private, age-restricted or region-locked)',
        RequestLimitExceededException() => 'YouTube is rate-limiting requests, try again later',
        SocketException() => 'The phone could not reach YouTube (check its internet connection)',
        FormatException(:final message) => message,
        _ => 'Download failed: ${e.toString().split('\n').first}',
      };
}

class _DownloadBlocked implements Exception {
  const _DownloadBlocked();
}

class _DownloadStalled implements Exception {
  const _DownloadStalled();
}
