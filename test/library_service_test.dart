import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_contoller/models/music_folder.dart';
import 'package:music_contoller/models/track.dart';
import 'package:music_contoller/services/library_service.dart';

void main() {
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

    final reopened = await open();
    expect(leftover.existsSync(), isFalse);
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

  test('file name helpers', () {
    expect(fileExtension('My Song.FLAC'), 'flac');
    expect(fileExtension('noext'), '');
    expect(titleFromFileName(r'C:\music\my_best_song.mp3'), 'my best song');
    expect(titleFromFileName('.hidden'), '.hidden');
  });
}
