import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/track.dart';
import 'library_service.dart';
import 'youtube_links.dart';
import 'ytdlp_service.dart';

enum JobStatus { queued, fetching, downloading, done, failed }

class DownloadJob {
  DownloadJob({
    required this.id,
    required this.url,
    required this.folderId,
    required this.video,
    this.title,
  });

  final String id;
  final String url;
  final String? folderId;

  /// Whether to also save the video and lyrics for the karaoke screen.
  final bool video;
  String? title;
  JobStatus status = JobStatus.queued;
  double progress = 0;
  String? error;

  bool get isFinished => status == JobStatus.done || status == JobStatus.failed;

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'title': title,
        'video': video,
        'status': status.name,
        'progress': progress,
        'error': error,
      };
}

/// Downloads YouTube links on the phone with yt-dlp, one job at a time (YouTube tends to
/// block parallel downloads from the same client).
class YoutubeService extends ChangeNotifier {
  YoutubeService(this._library, this._ytDlp);

  static const _maxPlaylistVideos = 300;
  static const _keepFinishedJobs = 30;
  static const _uuid = Uuid();

  final LibraryService _library;
  final YtDlpService _ytDlp;
  final List<DownloadJob> _jobs = [];
  bool _running = false;
  DateTime _lastProgressNotify = DateTime(0);

  List<DownloadJob> get jobs => List.unmodifiable(_jobs);

  /// Queues a video, or every video of a playlist link. When [folderId] is null,
  /// playlists go into a folder named after the playlist and single videos go to Unsorted.
  /// With [video], the karaoke video and lyrics are saved along with the audio.
  Future<List<DownloadJob>> enqueue(String url, {String? folderId, bool video = false}) async {
    final videoId = youtubeVideoId(url);
    final playlistId = videoId == null ? youtubePlaylistId(url) : null;

    final List<DownloadJob> created;
    if (videoId != null) {
      created = [
        DownloadJob(id: _uuid.v4(), url: youtubeVideoUrl(videoId), folderId: folderId, video: video),
      ];
    } else if (playlistId != null) {
      created = await _expandPlaylist(playlistId, folderId, video);
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

  Future<List<DownloadJob>> _expandPlaylist(String playlistId, String? folderId, bool video) async {
    final playlist =
        await _ytDlp.listPlaylist(youtubePlaylistUrl(playlistId), limit: _maxPlaylistVideos);
    if (playlist.videos.isEmpty) throw const FormatException('That playlist has no videos');
    final name = playlist.title ?? 'Playlist';
    final targetFolderId =
        folderId ?? (_library.folderByName(name) ?? _library.createFolder(name)).id;
    return [
      for (final v in playlist.videos)
        DownloadJob(id: _uuid.v4(), url: v.url, folderId: targetFolderId, video: video, title: v.title),
    ];
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
      YtDlpDownload download;
      try {
        download = await _download(job);
      } on YtDlpException catch (e) {
        // YouTube now and then refuses a stream URL it serves fine on the next try.
        if (!e.message.contains('HTTP Error 403')) rethrow;
        debugPrint('yt-dlp got a 403 for ${job.url}, trying once more');
        download = await _download(job);
      }
      try {
        job.title = download.title ?? job.title;
        await _library.importFiles(
          audio: download.audio,
          video: download.video,
          subtitles: download.subtitles,
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
      job
        ..status = JobStatus.done
        ..progress = 1;
    } catch (e, s) {
      debugPrint('YouTube download failed for ${job.url}: $e\n$s');
      job
        ..status = JobStatus.failed
        ..error = describeError(e);
    } finally {
      notifyListeners();
    }
  }

  Future<YtDlpDownload> _download(DownloadJob job) {
    job
      ..status = JobStatus.fetching
      ..progress = 0;
    notifyListeners();
    return _ytDlp.download(job.url, video: job.video, onProgress: (fraction) {
      job
        ..status = JobStatus.downloading
        ..progress = fraction;
      _notifyProgress();
    });
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

  /// A short explanation for the web page. yt-dlp's own messages are mostly clear
  /// ("Video unavailable", "Private video"); a few common ones get a hint.
  @visibleForTesting
  static String describeError(Object e) => switch (e) {
        YtDlpStalled() => 'yt-dlp stopped making progress, try again',
        YtDlpException(:final message) when message.contains('HTTP Error 429') =>
          'YouTube is rate-limiting this phone, try again in a few minutes',
        YtDlpException(:final message) when message.contains('not a bot') =>
          'YouTube wants to check this phone is not a bot, try again later',
        YtDlpException(:final message)
            when message.contains('Failed to resolve') ||
                message.contains('Network is unreachable') ||
                message.contains('No address associated') =>
          'The phone could not reach YouTube (check its internet connection)',
        YtDlpException(:final message) => message,
        FileSystemException() => 'The phone could not save the download (is its storage full?)',
        FormatException(:final message) => message,
        _ => 'Download failed: ${e.toString().split('\n').first}',
      };
}
