import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/music_folder.dart';
import '../models/track.dart';

class LibraryService extends ChangeNotifier {
  static const audioExtensions = {
    'mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'wav', 'flac', 'webm', 'mp4',
  };
  static const _maxNameLength = 80;
  static const _uuid = Uuid();

  late final Directory _root;
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
    if (missing.isNotEmpty) {
      _tracks.removeWhere(missing.contains);
      _save();
    }
  }

  String pathOf(Track track) => '${_root.path}/${track.fileName}';

  MusicFolder? folderById(String id) => _folders.where((f) => f.id == id).firstOrNull;

  MusicFolder? folderByName(String name) {
    final target = _normalize(name).toLowerCase();
    return _folders.where((f) => f.name.toLowerCase() == target).firstOrNull;
  }

  Track? trackById(String id) => _tracks.where((t) => t.id == id).firstOrNull;

  List<Track> tracksIn(String folderId) =>
      _tracks.where((t) => t.folderId == folderId).toList();

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

  /// Streams [data] straight to disk so large uploads/downloads never sit in memory.
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
    final id = _uuid.v4();
    final fileName = 'tracks/$id.$ext';
    final partial = File('${_root.path}/$fileName.part');
    try {
      // Not IOSink.addStream: it swallows the stream's error and close() then throws "File closed".
      final file = await partial.open(mode: FileMode.write);
      try {
        await for (final chunk in data) {
          await file.writeFrom(chunk);
        }
      } finally {
        await file.close();
      }
      await partial.rename('${_root.path}/$fileName');
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }

    final track = Track(
      id: id,
      title: _cleanName(title, fallback: 'Untitled'),
      artist: artist,
      fileName: fileName,
      folderId: (folderId != null && folderById(folderId) != null)
          ? folderId
          : MusicFolder.unsortedId,
      durationMs: durationMs,
      source: source,
      sourceUrl: sourceUrl,
      addedAt: DateTime.now(),
    );
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
    final file = File(pathOf(track));
    if (await file.exists()) await file.delete();
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
