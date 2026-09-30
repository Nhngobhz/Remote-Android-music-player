import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService extends ChangeNotifier {
  SettingsService._(this._prefs, this._pin);

  static const _pinKey = 'pin';

  final SharedPreferences _prefs;
  String _pin;

  String get pin => _pin;

  static Future<SettingsService> load() async {
    final prefs = await SharedPreferences.getInstance();
    var pin = prefs.getString(_pinKey);
    if (pin == null) {
      pin = _generatePin();
      await prefs.setString(_pinKey, pin);
    }
    return SettingsService._(prefs, pin);
  }

  Future<void> regeneratePin() async {
    _pin = _generatePin();
    await _prefs.setString(_pinKey, _pin);
    notifyListeners();
  }

  static String _generatePin() =>
      Random.secure().nextInt(1000000).toString().padLeft(6, '0');
}
