import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pathguide/settings/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('預設是正常語速', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final s = await AppSettings.load();
    expect(s.speechSpeed, SpeechSpeed.normal);
    expect(s.ttsRate, 0.45);
  });

  test('設定後會持久化，重新載入仍在', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final s = await AppSettings.load();
    await s.setSpeechSpeed(SpeechSpeed.slow);
    expect(s.ttsRate, 0.35);

    final again = await AppSettings.load();
    expect(again.speechSpeed, SpeechSpeed.slow);
  });

  test('未知的存檔值不會讓載入失敗（回退預設）', () async {
    SharedPreferences.setMockInitialValues(
      <String, Object>{'speech_speed': 'turbo'},
    );
    final s = await AppSettings.load();
    expect(s.speechSpeed, SpeechSpeed.normal);
  });

  test('真的改變時才通知監聽者', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final s = await AppSettings.load();
    var notified = 0;
    s.addListener(() => notified++);

    await s.setSpeechSpeed(SpeechSpeed.normal); // 沒變
    expect(notified, 0);
    await s.setSpeechSpeed(SpeechSpeed.fast); // 變了
    expect(notified, 1);
  });
}
