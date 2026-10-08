import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/music_folder.dart';
import '../services/audio_player_service.dart';
import '../services/control_server.dart';
import '../services/library_service.dart';
import '../services/network_info_service.dart';
import '../services/settings_service.dart';
import '../services/youtube_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.settings,
    required this.library,
    required this.player,
    required this.youtube,
    required this.server,
  });

  final SettingsService settings;
  final LibraryService library;
  final PlayerHandler player;
  final YoutubeService youtube;
  final ControlServer server;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  String? _serverError;
  bool _serverStarting = true;
  List<String> _addresses = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Permission.notification.request();
    _startServer();
    _loadAddresses();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Wi-Fi may have changed while the app was in the background.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadAddresses();
  }

  Future<void> _startServer() async {
    setState(() {
      _serverStarting = true;
      _serverError = null;
    });
    try {
      await widget.server.start();
    } catch (e) {
      _serverError = 'Could not start the remote control server: $e';
    }
    if (mounted) setState(() => _serverStarting = false);
  }

  Future<void> _loadAddresses() async {
    final addresses = await localIpAddresses();
    if (mounted) setState(() => _addresses = addresses);
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      final message = e is StateError ? e.message : '$e';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Music Controller'),
        actions: [
          IconButton(
            tooltip: 'Refresh address',
            icon: const Icon(Icons.refresh),
            onPressed: _loadAddresses,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildConnectCard(context),
          const SizedBox(height: 12),
          _NowPlayingCard(player: widget.player, run: _run),
          const SizedBox(height: 12),
          _DownloadsCard(youtube: widget.youtube),
          _LibrarySection(library: widget.library, player: widget.player, run: _run),
        ],
      ),
    );
  }

  Widget _buildConnectCard(BuildContext context) {
    final theme = Theme.of(context);
    final Widget content;
    if (_serverStarting) {
      content = const Center(child: CircularProgressIndicator());
    } else if (_serverError != null) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_serverError!, style: TextStyle(color: theme.colorScheme.error)),
          const SizedBox(height: 8),
          FilledButton(onPressed: _startServer, child: const Text('Try again')),
        ],
      );
    } else if (_addresses.isEmpty) {
      content = const Text(
        'Connect this phone to Wi-Fi (or turn on its hotspot and connect the PC to it) '
        'so your PC can reach it, then tap refresh.',
      );
    } else {
      final urls = _addresses.map((ip) => 'http://$ip:${widget.server.port}').toList();
      content = ListenableBuilder(
        listenable: widget.settings,
        builder: (context, _) => Wrap(
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('On a PC on the same Wi-Fi, open:'),
                  SelectableText(urls.first,
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                  for (final other in urls.skip(1))
                    SelectableText('or $other', style: theme.textTheme.bodySmall),
                  const SizedBox(height: 12),
                  const Text('PIN'),
                  Row(
                    children: [
                      SelectableText(
                        widget.settings.pin,
                        style: theme.textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 6),
                      ),
                      const SizedBox(width: 8),
                      TextButton(onPressed: _confirmNewPin, child: const Text('New PIN')),
                    ],
                  ),
                ],
              ),
            ),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(6),
              child: QrImageView(data: urls.first, size: 132),
            ),
          ],
        ),
      );
    }
    return Card(
      child: Padding(padding: const EdgeInsets.all(16), child: content),
    );
  }

  Future<void> _confirmNewPin() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Make a new PIN?'),
        content: const Text('Any PC that is connected now will have to enter the new PIN.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('New PIN')),
        ],
      ),
    );
    if (confirmed == true) await widget.settings.regeneratePin();
  }
}

String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

class _NowPlayingCard extends StatelessWidget {
  const _NowPlayingCard({required this.player, required this.run});

  final PlayerHandler player;
  final Future<void> Function(Future<void> Function()) run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: StreamBuilder<MediaItem?>(
          stream: player.mediaItem,
          builder: (context, itemSnap) {
            final item = itemSnap.data;
            return StreamBuilder<PlaybackState>(
              stream: player.playbackState,
              builder: (context, stateSnap) {
                final state = stateSnap.data;
                final playing = state?.playing ?? false;
                final duration = item?.duration ?? Duration.zero;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(item?.title ?? 'Nothing playing',
                        style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (item?.artist != null || item?.album != null)
                      Text([item?.artist, item?.album].whereType<String>().join(' · '),
                          style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    StreamBuilder<Duration>(
                      stream: AudioService.position,
                      builder: (context, posSnap) {
                        final max = duration.inMilliseconds.toDouble();
                        final pos = (posSnap.data ?? Duration.zero).inMilliseconds.toDouble().clamp(0.0, max);
                        return Row(
                          children: [
                            Text(_formatDuration(Duration(milliseconds: pos.toInt())),
                                style: theme.textTheme.bodySmall),
                            Expanded(
                              child: Slider(
                                value: max > 0 ? pos : 0,
                                max: max > 0 ? max : 1,
                                onChanged: max > 0
                                    ? (v) => player.seek(Duration(milliseconds: v.toInt()))
                                    : null,
                              ),
                            ),
                            Text(_formatDuration(duration), style: theme.textTheme.bodySmall),
                          ],
                        );
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          tooltip: 'Shuffle',
                          isSelected: player.shuffleEnabled,
                          icon: const Icon(Icons.shuffle),
                          onPressed: () => run(() => player.setShuffle(!player.shuffleEnabled)),
                        ),
                        IconButton(
                          tooltip: 'Previous',
                          icon: const Icon(Icons.skip_previous),
                          onPressed: () => run(player.skipToPrevious),
                        ),
                        IconButton.filled(
                          tooltip: playing ? 'Pause' : 'Play',
                          iconSize: 36,
                          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                          onPressed: () => run(playing ? player.pause : player.play),
                        ),
                        IconButton(
                          tooltip: 'Next',
                          icon: const Icon(Icons.skip_next),
                          onPressed: () => run(player.skipToNext),
                        ),
                        IconButton(
                          tooltip: 'Repeat: ${player.repeatMode.name}',
                          isSelected: player.repeatMode != PlaybackRepeat.off,
                          icon: Icon(player.repeatMode == PlaybackRepeat.one ? Icons.repeat_one : Icons.repeat),
                          onPressed: () => run(() => player.setRepeat(switch (player.repeatMode) {
                                PlaybackRepeat.off => PlaybackRepeat.all,
                                PlaybackRepeat.all => PlaybackRepeat.one,
                                PlaybackRepeat.one => PlaybackRepeat.off,
                              })),
                        ),
                      ],
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _DownloadsCard extends StatelessWidget {
  const _DownloadsCard({required this.youtube});

  final YoutubeService youtube;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: youtube,
      builder: (context, _) {
        final active = youtube.jobs.where((j) => !j.isFinished).toList();
        if (active.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Downloading (${active.length})', style: Theme.of(context).textTheme.titleSmall),
                  for (final job in active.take(5)) ...[
                    const SizedBox(height: 8),
                    Text(job.title ?? job.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: job.status == JobStatus.downloading ? job.progress : null,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LibrarySection extends StatelessWidget {
  const _LibrarySection({required this.library, required this.player, required this.run});

  final LibraryService library;
  final PlayerHandler player;
  final Future<void> Function(Future<void> Function()) run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final folders = library.folders;
        final hasTracks = library.tracks.isNotEmpty;
        return StreamBuilder<MediaItem?>(
          stream: player.mediaItem,
          builder: (context, snap) {
            final currentId = snap.data?.id;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Library', style: theme.textTheme.titleMedium)),
                    TextButton.icon(
                      onPressed: hasTracks ? () => run(() => player.playFolder(null, shuffle: false)) : null,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play all'),
                    ),
                    TextButton.icon(
                      onPressed: hasTracks ? () => run(() => player.playFolder(null, shuffle: true)) : null,
                      icon: const Icon(Icons.shuffle),
                      label: const Text('Shuffle all'),
                    ),
                  ],
                ),
                if (!hasTracks)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'No music yet. Open the web address above on your PC to paste '
                      'YouTube links or upload music and video files.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                for (final folder in folders)
                  if (!(folder.isUnsorted && library.tracksIn(folder.id).isEmpty))
                    _FolderTile(
                      folder: folder,
                      library: library,
                      player: player,
                      currentId: currentId,
                      run: run,
                    ),
              ],
            );
          },
        );
      },
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.folder,
    required this.library,
    required this.player,
    required this.currentId,
    required this.run,
  });

  final MusicFolder folder;
  final LibraryService library;
  final PlayerHandler player;
  final String? currentId;
  final Future<void> Function(Future<void> Function()) run;

  @override
  Widget build(BuildContext context) {
    final tracks = library.tracksIn(folder.id);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.folder),
        title: Text(folder.name),
        subtitle: Text('${tracks.length} song${tracks.length == 1 ? '' : 's'}'),
        trailing: IconButton(
          tooltip: 'Play folder',
          icon: const Icon(Icons.play_circle),
          onPressed: tracks.isEmpty ? null : () => run(() => player.playFolder(folder.id)),
        ),
        children: [
          for (final track in tracks)
            ListTile(
              dense: true,
              selected: track.id == currentId,
              leading: Icon(track.id == currentId
                  ? Icons.equalizer
                  : (track.hasVideo ? Icons.movie_outlined : Icons.music_note)),
              title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: track.artist == null ? null : Text(track.artist!, maxLines: 1),
              onTap: () => run(() => player.playFolder(folder.id, startTrackId: track.id)),
            ),
        ],
      ),
    );
  }
}
