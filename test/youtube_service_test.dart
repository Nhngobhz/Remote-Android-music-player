import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_contoller/models/track.dart';
import 'package:music_contoller/services/library_service.dart';
import 'package:music_contoller/services/youtube_service.dart';
import 'package:music_contoller/services/ytdlp_service.dart';

import 'fake_ytdlp.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late LibraryService library;
  late FakeYtDlp fake;
  late YoutubeService youtube;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('youtube_test');
    library = LibraryService();
    await library.init(root: Directory('${root.path}/library'));
    fake = FakeYtDlp();
    youtube = YoutubeService(library, YtDlpService(workRoot: Directory('${root.path}/work')));
  });

  tearDown(() async {
    fake.dispose();
    await library.flush();
    await root.delete(recursive: true);
  });

  /// Waits until every job has finished.
  Future<void> settle() async {
    while (youtube.jobs.any((j) => !j.isFinished)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('a video link with video becomes a track with its video and lyrics', () async {
    fake.subtitles = ['en', 'km'];
    final job = (await youtube.enqueue('https://youtu.be/kJQP7kiw5Fk?si=x', video: true)).single;
    expect(job.url, 'https://www.youtube.com/watch?v=kJQP7kiw5Fk');
    await settle();

    expect(job.status, JobStatus.done);
    expect(job.toJson()['video'], isTrue);
    final track = library.tracks.single;
    expect(track.title, 'Test Song');
    expect(track.artist, 'Channel');
    expect(track.durationMs, 200000);
    expect(track.source, TrackSource.youtube);
    expect(track.sourceUrl, job.url);
    expect(await File(library.pathOf(track)).readAsBytes(), [1, 2, 3]);
    expect(await File(library.videoPathOf(track)!).readAsBytes(), [4, 5, 6, 7]);
    expect(track.subtitleFileNames.keys, unorderedEquals(['en', 'km']));
    expect(await File(library.subtitlePathOf(track, 'km')!).readAsString(), contains('km'));
    expect(Directory('${root.path}/work').listSync(), isEmpty, reason: 'download folder removed');
  });

  test('without video only the audio is saved', () async {
    await youtube.enqueue('https://www.youtube.com/watch?v=kJQP7kiw5Fk');
    await settle();

    final track = library.tracks.single;
    expect(track.hasVideo, isFalse);
    expect(track.subtitleFileNames, isEmpty);
    expect(fake.runs.single.options, isNot(contains('--write-subs')));
  });

  test('a playlist link fills a folder named after the playlist', () async {
    fake.playlistJson = '{"title": "Karaoke Night", "entries": ['
        '{"id": "aaaaaaaaaaa", "title": "Song A"}, {"id": "bbbbbbbbbbb", "title": "Song B"}]}';
    final jobs = await youtube.enqueue('https://www.youtube.com/playlist?list=PLabcdefghijk123', video: true);

    expect(fake.runs.first.url, 'https://www.youtube.com/playlist?list=PLabcdefghijk123');
    expect(jobs.map((j) => j.title), ['Song A', 'Song B']);
    final folder = library.folderByName('Karaoke Night')!;
    expect(jobs.every((j) => j.folderId == folder.id && j.video), isTrue);
    await settle();
    expect(library.tracksIn(folder.id), hasLength(2));
  });

  test('a 403 is retried once, other errors fail the job with yt-dlp\'s reason', () async {
    fake.errors.add(PlatformException(code: 'FAILED', message: 'ERROR: unable to download video data: HTTP Error 403: Forbidden'));
    final retried = (await youtube.enqueue('https://www.youtube.com/watch?v=aaaaaaaaaaa')).single;
    await settle();
    expect(retried.status, JobStatus.done);
    expect(fake.runs, hasLength(2));

    fake.errors.add(PlatformException(code: 'FAILED', message: 'ERROR: [youtube] bbbbbbbbbbb: Private video'));
    final failed = (await youtube.enqueue('https://www.youtube.com/watch?v=bbbbbbbbbbb')).single;
    await settle();
    expect(failed.status, JobStatus.failed);
    expect(failed.error, 'Private video');

    youtube.retry(failed.id);
    await settle();
    expect(failed.status, JobStatus.done);
  });

  test('links that are not YouTube videos or playlists are refused', () async {
    await expectLater(youtube.enqueue('https://example.com/song'), throwsFormatException);
    expect(youtube.jobs, isEmpty);
  });

  test('common yt-dlp errors get a plain explanation', () {
    expect(YoutubeService.describeError(const YtDlpException('Unable to download webpage: HTTP Error 429: Too Many Requests')),
        contains('rate-limiting'));
    expect(YoutubeService.describeError(const YtDlpException("Sign in to confirm you're not a bot")),
        contains('not a bot'));
    expect(YoutubeService.describeError(const YtDlpStalled()), contains('try again'));
    expect(YoutubeService.describeError(const YtDlpException('Video unavailable')), 'Video unavailable');
  });
}
