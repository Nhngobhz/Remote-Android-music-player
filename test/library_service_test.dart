import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_contoller/models/music_folder.dart';
import 'package:music_contoller/models/track.dart';
import 'package:music_contoller/services/library_service.dart';

import 'fake_media_tools.dart';

void main() {
  // For the media channel that looks inside uploaded videos.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  final opened = <LibraryService>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library_test');
  });

  tearDown(() async {
    for (final library in opened) {
      await library.flush();
    }
    opened.clear();
    await root.delete(recursive: true);
  });

  Future<LibraryService> open() async {
    final library = LibraryService();
    await library.init(root: root);
    opened.add(library);
    return library;
  }

  Stream<List<int>> bytes(int n) => Stream.value(List.filled(n, 7));

  test('starts with an Unsorted folder', () async {
    final library = await open();
    expect(library.folders.map((f) => f.id), [MusicFolder.unsortedId]);
  });

  test('imports a track to disk and persists it across restarts', () async {
    final library = await open();
    final folder = library.createFolder('Morning');
    final track = await library.importStream(bytes(1024),
        extension: 'MP3', title: 'Song  A ', folderId: folder.id, source: TrackSource.upload);

    expect(track.title, 'Song A');
    expect(File(library.pathOf(track)).lengthSync(), 1024);
    expect(library.tracksIn(folder.id), hasLength(1));
    await library.flush();

    final reopened = await open();
    expect(reopened.folderByName('morning')?.id, folder.id);
    expect(reopened.trackById(track.id)?.folderId, folder.id);
  });

  test('unknown folder falls back to Unsorted and bad formats are rejected', () async {
    final library = await open();
    final track = await library.importStream(bytes(10),
        extension: 'm4a', title: 'x', folderId: 'nope', source: TrackSource.youtube);
    expect(track.folderId, MusicFolder.unsortedId);

    expect(
      () => library.importStream(bytes(10), extension: 'exe', title: 'x', source: TrackSource.upload),
      throwsArgumentError,
    );
  });

  test('a failed stream leaves no partial file or track behind', () async {
    final library = await open();
    final broken = Stream<List<int>>.error(const SocketException('lost'));
    await expectLater(
      library.importStream(broken, extension: 'mp3', title: 'x', source: TrackSource.youtube),
      throwsA(isA<SocketException>()),
    );
    expect(library.tracks, isEmpty);
    expect(Directory('${root.path}/tracks').listSync(), isEmpty);
  });

  test('partial files left by a killed app are removed on startup', () async {
    final library = await open();
    final track = await library.importStream(bytes(16),
        extension: 'mp3', title: 'Kept', source: TrackSource.upload);
    await library.flush();
    final leftover = File('${root.path}/tracks/abandoned.m4a.part')..writeAsBytesSync([1, 2, 3]);
    final upload = File('${root.path}/incoming/abandoned.mp4')..writeAsBytesSync([1, 2, 3]);

    final reopened = await open();
    expect(leftover.existsSync(), isFalse);
    expect(upload.existsSync(), isFalse);
    expect(reopened.tracks.map((t) => t.id), [track.id]);
    expect(File(reopened.pathOf(track)).existsSync(), isTrue);
  });

  test('deleting a folder moves its songs to Unsorted', () async {
    final library = await open();
    final folder = library.createFolder('Evening');
    final track = await library.importStream(bytes(5),
        extension: 'mp3', title: 't', folderId: folder.id, source: TrackSource.upload);

    library.deleteFolder(folder.id);
    expect(library.trackById(track.id)?.folderId, MusicFolder.unsortedId);
    expect(() => library.deleteFolder(MusicFolder.unsortedId), throwsArgumentError);
  });

  test('duplicate folder names are rejected case-insensitively', () async {
    final library = await open();
    library.createFolder('Jazz');
    expect(() => library.createFolder('jazz'), throwsArgumentError);
    expect(() => library.createFolder('   '), throwsArgumentError);

    final longName = 'Very long playlist title ' * 10;
    final folder = library.createFolder(longName);
    expect(library.folderByName(longName)?.id, folder.id,
        reason: 'lookups must match the truncated stored name');
  });

  test('moving, renaming and deleting a track', () async {
    final library = await open();
    final folder = library.createFolder('Pop');
    final track = await library.importStream(bytes(5),
        extension: 'mp3', title: 'old', source: TrackSource.upload);
    final removed = library.onTrackRemoved.first;

    library.updateTrack(track.id, title: 'new', folderId: folder.id);
    expect(library.trackById(track.id)?.title, 'new');
    expect(library.trackById(track.id)?.folderId, folder.id);

    final path = library.pathOf(track);
    await library.deleteTrack(track.id);
    expect(await removed, same(track));
    expect(File(path).existsSync(), isFalse);
    expect(library.tracks, isEmpty);
  });

  /// A file outside the library, like the ones yt-dlp saves.
  Future<File> download(String name, List<int> data) async {
    final dir = await Directory('${root.path}/download').create(recursive: true);
    return File('${dir.path}/$name').writeAsBytes(data);
  }

  test('importFiles moves the audio, video and subtitles into the library', () async {
    final library = await open();
    final track = await library.importFiles(
      audio: await download('audio.m4a', [1, 2]),
      video: await download('video.webm', [3, 4, 5]),
      subtitles: {'en': await download('subs.en.vtt', [6]), '../x': await download('subs.bad.vtt', [7])},
      title: 'Karaoke',
      source: TrackSource.youtube,
    );

    expect(await File(library.pathOf(track)).readAsBytes(), [1, 2]);
    expect(library.videoPathOf(track), endsWith('.video.webm'));
    expect(await File(library.videoPathOf(track)!).readAsBytes(), [3, 4, 5]);
    expect(track.subtitleFileNames.keys, unorderedEquals(['en', 'x']), reason: 'language names are made safe');
    expect(await File(library.subtitlePathOf(track, 'en')!).readAsBytes(), [6]);
    expect(Directory('${root.path}/download').listSync(), isEmpty, reason: 'moved, not copied');
    await library.flush();

    final reopened = await open();
    final again = reopened.trackById(track.id)!;
    expect(again.videoFileName, track.videoFileName);
    expect(again.subtitleFileNames, track.subtitleFileNames);

    final paths = [reopened.pathOf(again), reopened.videoPathOf(again)!, reopened.subtitlePathOf(again, 'en')!];
    await reopened.deleteTrack(again.id);
    expect(paths.where((p) => File(p).existsSync()), isEmpty, reason: 'all of the song\'s files go');
  });

  test('a lost video or subtitle file only takes that extra away', () async {
    final library = await open();
    final track = await library.importFiles(
      audio: await download('audio.m4a', [1]),
      video: await download('video.mp4', [2]),
      subtitles: {'en': await download('subs.en.vtt', [3])},
      title: 'Song',
      source: TrackSource.youtube,
    );
    await library.flush();
    await File(library.videoPathOf(track)!).delete();
    await File(library.subtitlePathOf(track, 'en')!).delete();

    final reopened = await open();
    final again = reopened.trackById(track.id)!;
    expect(again.hasVideo, isFalse);
    expect(again.subtitleFileNames, isEmpty);
  });

  test('importFiles refuses audio the phone can\'t play', () async {
    final library = await open();
    await expectLater(
      library.importFiles(audio: await download('audio.exe', [1]), title: 'x', source: TrackSource.youtube),
      throwsArgumentError,
    );
    expect(library.tracks, isEmpty);
  });

  List<FileSystemEntity> filesIn(String dir) => Directory('${root.path}/$dir').listSync();

  test('an uploaded video keeps its picture, and the phone plays its sound from a file of its own', () async {
    final media = FakeMediaTools();
    addTearDown(media.dispose);
    final library = await open();

    final track = await library.importStream(Stream.value([1, 2, 3]),
        extension: 'MP4', title: 'Karaoke', source: TrackSource.upload);

    expect(media.inputs.single, endsWith('.mp4'));
    expect(library.pathOf(track), endsWith('.m4a'));
    expect(await File(library.pathOf(track)).readAsBytes(), [9, 9]);
    expect(library.videoPathOf(track), endsWith('.video.mp4'));
    expect(await File(library.videoPathOf(track)!).readAsBytes(), [1, 2, 3]);
    expect(track.durationMs, 8000);
    expect(filesIn('incoming'), isEmpty);

    await library.deleteTrack(track.id);
    expect(filesIn('tracks'), isEmpty);
  });

  test('a video whose sound can\'t be copied out plays from the video file itself', () async {
    final media = FakeMediaTools()..audioExtension = null;
    addTearDown(media.dispose);
    final library = await open();

    final track = await library.importStream(Stream.value([1, 2, 3]),
        extension: 'mkv', title: 'Old rip', source: TrackSource.upload);
    expect(track.hasVideo, isTrue);
    expect(library.videoPathOf(track), library.pathOf(track));
    expect(await File(library.pathOf(track)).readAsBytes(), [1, 2, 3]);
    await library.flush();

    final reopened = await open();
    expect(reopened.trackById(track.id)?.hasVideo, isTrue);
    await reopened.deleteTrack(track.id);
    expect(filesIn('tracks'), isEmpty);
  });

  test('a video the phone can\'t look inside is kept for the browser to try', () async {
    final media = FakeMediaTools()..error = PlatformException(code: 'FAILED', message: 'unsupported');
    addTearDown(media.dispose);
    final library = await open();

    final track = await library.importStream(Stream.value([1]),
        extension: 'mov', title: 'Clip', source: TrackSource.upload);
    expect(library.videoPathOf(track), library.pathOf(track));
    expect(track.durationMs, isNull);
  });

  test('sound alone in a video container is an ordinary song', () async {
    final media = FakeMediaTools()..hasVideo = false;
    addTearDown(media.dispose);
    final library = await open();

    final track = await library.importStream(Stream.value([1, 2]),
        extension: 'webm', title: 'Opus', source: TrackSource.upload);
    expect(track.hasVideo, isFalse);
    expect(await File(library.pathOf(track)).readAsBytes(), [1, 2]);
    expect(filesIn('incoming'), isEmpty);
  });

  test('a video without sound is refused and leaves nothing behind', () async {
    final media = FakeMediaTools()..hasAudio = false;
    addTearDown(media.dispose);
    final library = await open();

    await expectLater(
      library.importStream(Stream.value([1]), extension: 'mp4', title: 'Silent', source: TrackSource.upload),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('no sound'))),
    );
    expect(library.tracks, isEmpty);
    expect([...filesIn('incoming'), ...filesIn('tracks')], isEmpty);
  });

  test('file name helpers', () {
    expect(fileExtension('My Song.FLAC'), 'flac');
    expect(fileExtension('noext'), '');
    expect(titleFromFileName(r'C:\music\my_best_song.mp3'), 'my best song');
    expect(titleFromFileName('.hidden'), '.hidden');
  });
}
