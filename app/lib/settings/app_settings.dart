import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播報速度。三個檔位對應 `flutter_tts` 的 speech rate。
///
/// 為什麼只有三檔而不是連續滑桿：滑桿對全盲使用者不可判斷（看不到刻度、
/// 也聽不出 0.01 的差別），三檔可用「慢／正常／快」直接唸出來。
enum SpeechSpeed {
  slow(0.35),
  normal(0.45),
  fast(0.55);

  const SpeechSpeed(this.ttsRate);

  /// 傳給 `flutter_tts.setSpeechRate` 的值。
  final double ttsRate;
}

/// 使用者的本機設定。目前只有播報速度。
///
/// 刻意**不**在這裡放雲端設定：跨端同步是雲能力（Spec 1 §3），
/// 混進來會讓「訪客也能完整使用」這句話變得難驗證。
class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);

  /// 測試與無存儲環境用。
  AppSettings.memory() : _prefs = null;

  static const String kSpeechSpeedKey = 'speech_speed';

  final SharedPreferences? _prefs;
  SpeechSpeed _speechSpeed = SpeechSpeed.normal;

  SpeechSpeed get speechSpeed => _speechSpeed;

  /// 目前的 TTS 語速，直接餵給 speaker。
  double get ttsRate => _speechSpeed.ttsRate;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = AppSettings(prefs);
    final raw = prefs.getString(kSpeechSpeedKey);
    // 未知值（舊版本寫的、或手改的）一律回退預設，不讓載入失敗——
    // 設定壞掉不該擋住一個導航輔具的啟動。
    if (raw != null) {
      for (final speed in SpeechSpeed.values) {
        if (speed.name == raw) settings._speechSpeed = speed;
      }
    }
    return settings;
  }

  Future<void> setSpeechSpeed(SpeechSpeed speed) async {
    if (speed == _speechSpeed) return;
    _speechSpeed = speed;
    notifyListeners();
    await _prefs?.setString(kSpeechSpeedKey, speed.name);
  }
}
