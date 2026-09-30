import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_contoller/services/audio_player_service.dart';
import 'package:music_contoller/services/library_service.dart';

/// Records play/pause instead of touching a real player.
class _CountingHandler extends PlayerHandler {
  _CountingHandler(super.library);

  int plays = 0;
  int pauses = 0;

  @override
  Future<void> play() async => plays++;

  @override
  Future<void> pause() async => pauses++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _CountingHandler handler;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.ryanheise.audio_session'), (_) async => null);
    root = await Directory.systemTemp.createTemp('player_test');
    final library = LibraryService();
    await library.init(root: root);
    handler = _CountingHandler(library);
  });

  tearDown(() => root.delete(recursive: true));

  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  test('a single media button press toggles playback once it settles', () async {
    await handler.click(MediaButton.media);
    expect(handler.plays, 0);
    await wait(900);
    expect(handler.plays, 1);
  });

  test('a held or bouncing button does nothing, then a later press works', () async {
    // Android repeats a held key after ~500 ms, then every ~50 ms.
    await handler.click(MediaButton.media);
    await wait(500);
    for (var i = 0; i < 20; i++) {
      await handler.click(MediaButton.media);
      await wait(50);
    }
    await wait(900);
    expect((handler.plays, handler.pauses), (0, 0));

    await handler.click(MediaButton.media);
    await wait(900);
    expect(handler.plays, 1);
  });
}
