import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/audio_player_service.dart';
import 'services/control_server.dart';
import 'services/library_service.dart';
import 'services/settings_service.dart';
import 'services/youtube_service.dart';
import 'services/ytdlp_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = await SettingsService.load();
  final library = LibraryService();
  await library.init();
  final player = await AudioService.init(
    builder: () => PlayerHandler(library),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.music_contoller.playback',
      androidNotificationChannelName: 'Music playback',
      // Staying in the foreground while paused keeps the app (and the web controller) alive.
      androidStopForegroundOnPause: false,
    ),
  );
  final ytDlp = YtDlpService();
  unawaited(ytDlp.start());
  final youtube = YoutubeService(library, ytDlp);
  final server = ControlServer(
    library: library,
    player: player,
    youtube: youtube,
    settings: settings,
    ytDlp: ytDlp,
  );

  runApp(MusicControllerApp(
    settings: settings,
    library: library,
    player: player,
    youtube: youtube,
    server: server,
  ));
}

class MusicControllerApp extends StatelessWidget {
  const MusicControllerApp({
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
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music Controller',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark),
      ),
      home: HomeScreen(
        settings: settings,
        library: library,
        player: player,
        youtube: youtube,
        server: server,
      ),
    );
  }
}
