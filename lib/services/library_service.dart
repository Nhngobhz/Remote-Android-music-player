import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/music_folder.dart';
import '../models/track.dart';
import 'media_tools.dart';

class LibraryService extends ChangeNotifier {
  /// Files the phone can play the sound of, video files included.
  static const audioExtensions = {
    'mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'wav', 'flac', 'webm', 'mp4', 'm4v', 'mov', 'mkv',
  };

  /// Video files for the karaoke screen, in containers browsers play.
  static const videoExtensions = {'mp4', 'm4v', 'mov', 'webm', 'mkv'};
  static const _maxNameLength = 80;
  static const _uuid = Uuid();

  late final Directory _root;
  late final Directory _incoming;
  late final File _manifest;

  final List<MusicFolder> _folders = [];
  final List<Track> _tracks = [];
  int _version = 0;
  Future<void> _pendingSave = Future.value();

  final _trackAdded = StreamController<Track>.broadcast();
  final _trackRemoved = StreamController<Track>.broadcast();

  List<MusicFolder> get folders => List.unmodifiable(_folders);
  List<Track> get tracks => List.unmodifiable(_tracks);

  /// Bumped on every change so clients can cheaply detect when to re-fetch.
  int get version => _version;
  Stream<Track> get onTrackAdded => _trackAdded.stream;
  Stream<Track> get onTrackRemoved => _trackRemoved.stream;

  Future<void> init({Directory? root}) async {
    _root = root ?? Directory('${(await getApplicationDocumentsDirectory()).path}/library');
    final tracksDir = await Directory('${_root.path}/tracks').create(recursive: true);
    // Leftovers from downloads or uploads cut off when the app was killed.
    await for (final entry in tracksDir.list()) {
      if (entry is File && entry.path.endsWith('.part')) await entry.delete();
    }
    _incoming = Directory('${_root.path}/incoming');
    if (await _incoming.exists()) await _incoming.delete(recursive: true);
    await _incoming.create();
    _manifest = File('${_root.path}/library.json');

    if (await _manifest.exists()) {
      final data = jsonDecode(await _manifest.readAsString()) as Map<String, dynamic>;
      _folders.addAll((data['folders'] as List)
          .map((e) => MusicFolder.fromJson(e as Map<String, dynamic>)));
      _tracks.addAll(
          (data['tracks'] as List).map((e) => Track.fromJson(e as Map<String, dynamic>)));
    }
    if (!_folders.any((f) => f.isUnsorted)) {
      _folders.insert(0, MusicFolder(id: MusicFolder.unsortedId, name: 'Unsorted'));
    }
    final missing = _tracks.where((t) => !File(pathOf(t)).existsSync()).toList();
    var changed = missing.isNotEmpty;
    _tracks.removeWhere(missing.contains);
    // A lost video or subtitle file only takes that extra away; the song still plays.
    for (final track in _tracks) {
      final video = track.videoFileName;
      if (video != null && !File(_pathFor(video)).existsSync()) {
        track.videoFileName = null;
        changed = true;
      }
      final before = track.subtitleFileNames.length;
      track.subtitleFileNames.removeWhere((_, name) => !File(_pathFor(name)).existsSync());
      changed |= track.subtitleFileNames.length != before;
    }
    if (changed) _save();
  }

  String pathOf(Track track) => _pathFor(track.fileName);

  String? videoPathOf(Track track) {
    final name = track.videoFileName;
    return name == null ? null : _pathFor(name);
  }

  String? subtitlePathOf(Track track, String language) {
    final name = track.subtitleFileNames[language];
    return name == null ? null : _pathFor(name);
  }

  String _pathFor(String fileName) => '${_root.path}/$fileName';

  MusicFolder? folderById(String id) => _folders.where((f) => f.id == id).firstOrNull;

  MusicFolder? folderByName(String name) {
    final target = _normalize(name).toLowerCase();
    return _folders.where((f) => f.name.toLowerCase() == target).firstOrNull;
  }

  Track? trackById(String id) => _tracks.where((t) => t.id == id).firstOrNull;

  List<Track> tracksIn(String folderId) =>
      _tracks.where((t) => t.folderId == folderId).toList();

  /// Songs whose title or artist has every word of [query] in it, ignoring case.
  List<Track> search(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return [];
    return _tracks.where((t) {
      final text = '${t.title} ${t.artist ?? ''}'.toLowerCase();
      return words.every(text.contains);
    }).toList();
  }

  MusicFolder createFolder(String name) {
    final clean = _cleanName(name);
    if (folderByName(clean) != null) {
      throw ArgumentError('A folder named "$clean" already exists');
    }
    final folder = MusicFolder(id: _uuid.v4(), name: clean);
    _folders.add(folder);
    _changed();
    return folder;
  }

  void renameFolder(String id, String name) {
    final folder = _requireFolder(id);
    if (folder.isUnsorted) throw ArgumentError('The Unsorted folder cannot be renamed');
    final clean = _cleanName(name);
    final existing = folderByName(clean);
    if (existing != null && existing.id != id) {
      throw ArgumentError('A folder named "$clean" already exists');
    }
    folder.name = clean;
    _changed();
  }

  void deleteFolder(String id) {
    final folder = _requireFolder(id);
    if (folder.isUnsorted) throw ArgumentError('The Unsorted folder cannot be deleted');
    for (final t in _tracks.where((t) => t.folderId == id)) {
      t.folderId = MusicFolder.unsortedId;
    }
    _folders.remove(folder);
    _changed();
  }

  /// Streams [data] straight to disk so large uploads never sit in memory. A video keeps
  /// its picture for the karaoke screen, and its sound is copied into a file of its own,
  /// so the phone plays the sound without decoding the picture.
  Future<Track> importStream(
    Stream<List<int>> data, {
    required String extension,
    required String title,
    required TrackSource source,
    String? folderId,
    String? artist,
    int? durationMs,
    String? sourceUrl,
  }) async {
    final ext = extension.toLowerCase();
    if (!audioExtensions.contains(ext)) {
      throw ArgumentError('Unsupported audio format: .$ext');
    }
    final file = File('${_incoming.path}/${_uuid.v4()}.$ext');
    VideoParts? parts;
    try {
      // Not IOSink.addStream: it swallows the stream's error and close() then throws "File closed".
      final sink = await file.open(mode: FileMode.write);
      try {
        await for (final chunk in data) {
          await sink.writeFrom(chunk);
        }
      } finally {
        await sink.close();
      }

      if (videoExtensions.contains(ext)) {
        parts = await MediaTools.splitVideo(file, '${file.path}.sound');
        if (parts != null && parts.hasVideo && !parts.hasAudio) {
          throw const FormatException('This video has no sound for the phone to play');
        }
      }
      // A video the phone couldn't look inside is still worth showing; the browser decides.
      final hasVideo = videoExtensions.contains(ext) && (parts?.hasVideo ?? true);
      return await importFiles(
        audio: parts?.audio ?? file,
        video: hasVideo ? file : null,
        title: title,
        source: source,
        folderId: folderId,
        artist: artist,
        durationMs: durationMs ?? parts?.durationMs,
        sourceUrl: sourceUrl,
      );
    } catch (_) {
      for (final leftover in [file, ?parts?.audio]) {
        if (await leftover.exists()) await leftover.delete();
      }
      rethrow;
    }
  }

  /// Moves downloaded files into the library: [audio] for the phone to play, and
  /// optionally a [video] and [subtitles] (WebVTT by language code) for the karaoke screen.
  /// [video] may be [audio] itself, for a video whose sound couldn't be split off.
  Future<Track> importFiles({
    required File audio,
    required String title,
    required TrackSource source,
    File? video,
    Map<String, File> subtitles = const {},
    String? folderId,
    String? artist,
    int? durationMs,
    String? sourceUrl,
  }) async {
    final ext = fileExtension(audio.path);
    if (!audioExtensions.contains(ext)) {
      throw ArgumentError('Unsupported audio format: .$ext');
    }
    final id = _uuid.v4();
    final moved = <File>[];
    Future<String> take(File file, String fileName) async {
      moved.add(await _moveInto(file, fileName));
      return fileName;
    }

    try {
      final fileName = await take(audio, 'tracks/$id.$ext');
      final videoFileName = video == null
          ? null
          : video.path == audio.path
              ? fileName
              : await take(video, 'tracks/$id.video.${fileExtension(video.path)}');
      final subtitleFileNames = <String, String>{};
      for (final MapEntry(key: language, value: file) in subtitles.entries) {
        final safe = language.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
        if (safe.isEmpty || subtitleFileNames.containsKey(safe)) continue;
        subtitleFileNames[safe] = await take(file, 'tracks/$id.$safe.vtt');
      }
      return _add(Track(
        id: id,
        title: _cleanName(title, fallback: 'Untitled'),
        artist: artist,
        fileName: fileName,
        videoFileName: videoFileName,
        subtitleFileNames: subtitleFileNames,
        folderId: _folderOrUnsorted(folderId),
        durationMs: durationMs,
        source: source,
        sourceUrl: sourceUrl,
        addedAt: DateTime.now(),
      ));
    } catch (_) {
      for (final file in moved) {
        await file.delete().catchError((_) => file);
      }
      rethrow;
    }
  }

  /// Renames [file] into the library, or copies it when it is on another drive. A copy
  /// goes through a .part file, so a crash never leaves half a file under the real name.
  Future<File> _moveInto(File file, String fileName) async {
    final target = _pathFor(fileName);
    try {
      return await file.rename(target);
    } on FileSystemException {
      final partial = await file.copy('$target.part');
      final copied = await partial.rename(target);
      await file.delete();
      return copied;
    }
  }

  String _folderOrUnsorted(String? folderId) =>
      (folderId != null && folderById(folderId) != null) ? folderId : MusicFolder.unsortedId;

  Track _add(Track track) {
    _tracks.add(track);
    _changed();
    _trackAdded.add(track);
    return track;
  }

  void updateTrack(String id, {String? title, String? folderId}) {
    final track = _requireTrack(id);
    if (title != null) track.title = _cleanName(title);
    if (folderId != null) track.folderId = _requireFolder(folderId).id;
    _changed();
  }

  Future<void> deleteTrack(String id) async {
    final track = _requireTrack(id);
    _tracks.remove(track);
    _changed();
    _trackRemoved.add(track);
    for (final name in {track.fileName, ?track.videoFileName, ...track.subtitleFileNames.values}) {
      final file = File(_pathFor(name));
      if (await file.exists()) await file.delete();
    }
  }

  MusicFolder _requireFolder(String id) =>
      folderById(id) ?? (throw ArgumentError('Folder not found'));

  Track _requireTrack(String id) => trackById(id) ?? (throw ArgumentError('Track not found'));

  static String _normalize(String name) {
    final clean = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.length > _maxNameLength ? clean.substring(0, _maxNameLength).trim() : clean;
  }

  String _cleanName(String name, {String? fallback}) {
    final clean = _normalize(name);
    if (clean.isNotEmpty) return clean;
    if (fallback != null) return fallback;
    throw ArgumentError('Name cannot be empty');
  }

  void _changed() {
    _version++;
    notifyListeners();
    _save();
  }

  void _save() {
    final json = jsonEncode({
      'folders': _folders.map((f) => f.toJson()).toList(),
      'tracks': _tracks.map((t) => t.toJson()).toList(),
    });
    // Serialize writes, and write-then-rename so a crash never leaves a half-written manifest.
    _pendingSave = _pendingSave.then((_) async {
      final tmp = File('${_manifest.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(_manifest.path);
    }).catchError((Object e) => debugPrint('Failed to save library: $e'));
  }

  /// Completes once all queued manifest writes have hit disk.
  Future<void> flush() => _pendingSave;
}

String fileExtension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
}

String titleFromFileName(String fileName) {
  final base = fileName.split(RegExp(r'[/\\]')).last;
  final dot = base.lastIndexOf('.');
  return (dot > 0 ? base.substring(0, dot) : base).replaceAll('_', ' ');
}
