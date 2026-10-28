import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tts/announcer.dart' show kMinSpeakScore;

enum AppLanguage { chinese, english }

/// The three user-facing speech rates map to the values expected by
/// `flutter_tts`. The labels deliberately describe relative speed rather than
/// exposing implementation-specific decimal values.
enum SpeechSpeed {
  slow('0.8 倍速', 0.35),
  normal('1 倍速', 0.45),
  fast('1.2 倍速', 0.55);

  const SpeechSpeed(this.label, this.rate);

  final String label;
  final double rate;

  static SpeechSpeed fromStoredRate(double? value) {
    return SpeechSpeed.values.firstWhere(
      (speed) => (speed.rate - (value ?? normal.rate)).abs() < 0.001,
      orElse: () => normal,
    );
  }
}

/// Small app-wide preference controller. Only preferences that are real and
/// already supported by the product live here; future features never write
/// placeholder values to storage.
class AppSettings extends ChangeNotifier {
  AppSettings._({
    required this._preferences,
    SpeechSpeed? speed,
    double? speakThreshold,
    AppLanguage language = AppLanguage.chinese,
  }) : _speechSpeed = speed ?? SpeechSpeed.normal,
       // ignore: prefer_initializing_formals
       _language = language,
       _speakThreshold = speakThreshold ?? kMinSpeakScore;

  static const String speechRateKey = 'speech_rate';
  static const String speakThresholdKey = 'speak_threshold';
  static const String languageKey = 'app_language';
  AppLanguage _language;
  AppLanguage get language => _language;
  Future<void> setLanguage(AppLanguage value) async {
    if (_language == value) return;
    _language = value;
    notifyListeners();
    await _preferences?.setString(languageKey, value.name);
  }

  final SharedPreferences? _preferences;
  SpeechSpeed _speechSpeed;
  double _speakThreshold;

  double get speakThreshold => _speakThreshold;

  Future<void> setSpeakThreshold(double value) async {
    if (!value.isFinite) return;
    final next = value.clamp(0.05, 0.95);
    if (next == _speakThreshold) return;
    _speakThreshold = next;
    notifyListeners();
    await _preferences?.setDouble(speakThresholdKey, next);
  }

  /// Test and preview fallback. Production uses [load], which persists values.
  factory AppSettings.memory({
    SpeechSpeed speed = SpeechSpeed.normal,
    AppLanguage language = AppLanguage.chinese,
  }) => AppSettings._(preferences: null, speed: speed, language: language);

  static Future<AppSettings> load() async {
    final preferences = await SharedPreferences.getInstance();
    return AppSettings._(
      preferences: preferences,
      language: preferences.getString(languageKey) == 'english'
          ? AppLanguage.english
          : AppLanguage.chinese,
      speed: SpeechSpeed.fromStoredRate(preferences.getDouble(speechRateKey)),
      speakThreshold: _restoreSpeakThreshold(
        preferences.getDouble(speakThresholdKey),
      ),
    );
  }

  static double _restoreSpeakThreshold(double? value) =>
      value != null && value.isFinite
      ? value.clamp(0.05, 0.95)
      : kMinSpeakScore;

  SpeechSpeed get speechSpeed => _speechSpeed;

  Future<void> setSpeechSpeed(SpeechSpeed next) async {
    if (next == _speechSpeed) return;
    _speechSpeed = next;
    notifyListeners();
    // The change remains useful for this session if storage ever fails.
    await _preferences?.setDouble(speechRateKey, next.rate);
  }
}
