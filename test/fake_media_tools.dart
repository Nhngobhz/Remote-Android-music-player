import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const mediaChannel = MethodChannel('music_contoller/media');

/// Stands in for MediaTools.kt, answering 'splitVideo' the way it does for a file with the
/// streams set here.
class FakeMediaTools {
  FakeMediaTools() {
    _messenger.setMockMethodCallHandler(mediaChannel, _handle);
  }

  final _messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  bool hasVideo = true;
  bool hasAudio = true;

  /// The extension the copied sound gets; null for a codec MediaMuxer can't hold.
  String? audioExtension = 'm4a';
  int durationMs = 8000;

  /// Thrown instead of answering, as when Android can't read the file.
  PlatformException? error;

  /// The files looked at, in order.
  final inputs = <String>[];

  void dispose() => _messenger.setMockMethodCallHandler(mediaChannel, null);

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != 'splitVideo') return null;
    final args = call.arguments as Map;
    inputs.add(args['input'] as String);
    if (error != null) throw error!;
    String? audio;
    if (hasVideo && hasAudio && audioExtension != null) {
      audio = '${args['output']}.$audioExtension';
      await File(audio).writeAsBytes([9, 9]);
    }
    return {'hasVideo': hasVideo, 'hasAudio': hasAudio, 'audio': audio, 'durationMs': durationMs};
  }
}
