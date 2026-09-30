import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/track.dart';
import 'library_service.dart';

enum PlaybackRepeat { off, all, one }

class PlayerHandler extends BaseAudioHandler with SeekHandler {
  PlayerHandler(this._library) {
    _player.playbackEventStream.listen((_) => _broadcastState());
    _player.shuffleModeEnabledStream.listen((_) => _broadcastState());
    _player.loopModeStream.listen((_) => _broadcastState());
    _player.errorStream.listen((e) => debugPrint('Playback error: ${e.message}'));
    _player.currentIndexStream.listen(_onIndexChanged);
    _player.durationStream.listen(_onDurationChanged);
    _library.onTrackAdded.listen(_onTrackAdded);
    _library.onTrackRemoved.listen(_onTrackRemoved);
    // Background music should keep going rather than stop at the end of a folder.
    _player.setLoopMode(LoopMode.all);
  }

  /// How long a hardware media button must stay quiet before its press counts.
  static const _buttonSettleTime = Duration(milliseconds: 700);

  final LibraryService _library;
  final _player = AudioPlayer(maxSkipsOnError: 3);
  final _random = Random();
  DateTime _lastButtonPress = DateTime(0);
  Timer? _pendingButtonPress;

  List<Track> _queueTracks = [];

  /// Folder the queue was built from; null means "all music".
  String? _queueFolderId;

  bool get shuffleEnabled => _player.shuffleModeEnabled;
  PlaybackRepeat get repeatMode => switch (_player.loopMode) {
        LoopMode.off => PlaybackRepeat.off,
        LoopMode.all => PlaybackRepeat.all,
        LoopMode.one => PlaybackRepeat.one,
      };

  /// Replaces the queue with a folder's tracks (or all tracks when [folderId] is null) and plays.
  Future<void> playFolder(String? folderId, {String? startTrackId, bool? shuffle}) async {
    final tracks = folderId == null ? _library.tracks : _library.tracksIn(folderId);
    if (tracks.isEmpty) throw StateError('There are no songs to play here yet');

    if (shuffle != null) await _player.setShuffleModeEnabled(shuffle);
    var startIndex = startTrackId == null ? -1 : tracks.indexWhere((t) => t.id == startTrackId);
    if (startIndex < 0) {
      startIndex = _player.shuffleModeEnabled ? _random.nextInt(tracks.length) : 0;
    }

    _queueFolderId = folderId;
    _queueTracks = List.of(tracks);
    queue.add(_queueTracks.map(_toMediaItem).toList());
    await _player.setAudioSources(
      _queueTracks.map(_toSource).toList(),
      initialIndex: startIndex,
      shuffleOrder: DefaultShuffleOrder(random: _random),
    );
    unawaited(_player.play());
  }

  // just_audio's play() only completes when playback stops, so never await it here.
  @override
  Future<void> play() async {
    if (_queueTracks.isEmpty) {
      await playFolder(null);
    } else {
      unawaited(_player.play());
    }
  }

  @override
  Future<void> pause() => _player.pause();

  /// Presses from headset, USB and Bluetooth media buttons (not the notification or lock
  /// screen, which call play/pause directly). Some USB-C audio adapters report their
  /// button as held down, e.g. with a 3-pole aux cable, and Android then repeats the
  /// press every ~50 ms. A press only counts once no other press follows it, so a stuck
  /// or bouncing button does nothing instead of flipping playback on and off.
  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    final now = DateTime.now();
    final repeated = now.difference(_lastButtonPress) < _buttonSettleTime;
    _lastButtonPress = now;
    _pendingButtonPress?.cancel();
    if (repeated) return;
    _pendingButtonPress = Timer(_buttonSettleTime, () => super.click(button));
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _player.seekToNext();

  @override
  Future<void> skipToPrevious() async {
    if (_player.position > const Duration(seconds: 3) || !_player.hasPrevious) {
      await _player.seek(Duration.zero);
    } else {
      await _player.seekToPrevious();
    }
  }

  @override
  Future<void> skipToQueueItem(int index) => _player.seek(Duration.zero, index: index);

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      setShuffle(shuffleMode != AudioServiceShuffleMode.none);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) => setRepeat(switch (repeatMode) {
        AudioServiceRepeatMode.none => PlaybackRepeat.off,
        AudioServiceRepeatMode.one => PlaybackRepeat.one,
        AudioServiceRepeatMode.all || AudioServiceRepeatMode.group => PlaybackRepeat.all,
      });

  Future<void> setShuffle(bool enabled) async {
    if (enabled) await _player.shuffle();
    await _player.setShuffleModeEnabled(enabled);
  }

  Future<void> setRepeat(PlaybackRepeat mode) => _player.setLoopMode(switch (mode) {
        PlaybackRepeat.off => LoopMode.off,
        PlaybackRepeat.all => LoopMode.all,
        PlaybackRepeat.one => LoopMode.one,
      });

  Future<void> setVolume(double volume) => _player.setVolume(volume.clamp(0.0, 1.0));

  Track? get currentTrack {
    final index = _player.currentIndex;
    if (index == null || index >= _queueTracks.length) return null;
    return _queueTracks[index];
  }

  Map<String, dynamic> status() {
    final track = currentTrack;
    return {
      'playing': _player.playing,
      'processing': _player.processingState.name,
      'track': track == null
          ? null
          : {
              'id': track.id,
              'title': _library.trackById(track.id)?.title ?? track.title,
              'artist': track.artist,
              'folderId': track.folderId,
            },
      'positionMs': _player.position.inMilliseconds,
      'durationMs': _player.duration?.inMilliseconds,
      'shuffle': _player.shuffleModeEnabled,
      'repeat': repeatMode.name,
      'volume': _player.volume,
      'queueSource': _queueTracks.isEmpty ? null : (_queueFolderId ?? 'all'),
      'queueLength': _queueTracks.length,
    };
  }

  MediaItem _toMediaItem(Track t) => MediaItem(
        id: t.id,
        title: t.title,
        artist: t.artist,
        album: _library.folderById(t.folderId)?.name,
        duration: t.durationMs == null ? null : Duration(milliseconds: t.durationMs!),
      );

  AudioSource _toSource(Track t) =>
      AudioSource.file(_library.pathOf(t), tag: _toMediaItem(t));

  void _onIndexChanged(int? index) {
    final items = queue.value;
    if (index != null && index < items.length) mediaItem.add(items[index]);
  }

  // Uploaded files have no known duration until loaded; fill it in so the lock screen shows a seek bar.
  void _onDurationChanged(Duration? duration) {
    final item = mediaItem.valueOrNull;
    if (duration != null && item != null && item.duration == null) {
      mediaItem.add(item.copyWith(duration: duration));
    }
  }

  Future<void> _onTrackAdded(Track track) async {
    if (_queueTracks.isEmpty) return;
    if (_queueFolderId != null && _queueFolderId != track.folderId) return;
    _queueTracks.add(track);
    queue.add([...queue.value, _toMediaItem(track)]);
    await _player.addAudioSource(_toSource(track));
  }

  Future<void> _onTrackRemoved(Track track) async {
    final index = _queueTracks.indexWhere((t) => t.id == track.id);
    if (index < 0) return;
    _queueTracks.removeAt(index);
    queue.add([...queue.value]..removeAt(index));
    await _player.removeAudioSourceAt(index);
  }

  void _broadcastState() {
    final playing = _player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: switch (_player.processingState) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      },
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _player.currentIndex,
      shuffleMode:
          _player.shuffleModeEnabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      repeatMode: switch (repeatMode) {
        PlaybackRepeat.off => AudioServiceRepeatMode.none,
        PlaybackRepeat.all => AudioServiceRepeatMode.all,
        PlaybackRepeat.one => AudioServiceRepeatMode.one,
      },
    ));
  }
}
