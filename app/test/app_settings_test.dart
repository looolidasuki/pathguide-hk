import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('speech speed defaults to one times speed', () async {
    final settings = await AppSettings.load();

    expect(settings.speechSpeed, SpeechSpeed.normal);
    expect(settings.speechSpeed.label, '1 倍速');
    expect(settings.speechSpeed.rate, 0.45);
  });

  test(
    'speech speed is restored after a new settings controller is loaded',
    () async {
      final settings = await AppSettings.load();
      await settings.setSpeechSpeed(SpeechSpeed.fast);

      final restored = await AppSettings.load();
      expect(restored.speechSpeed, SpeechSpeed.fast);
      expect(restored.speechSpeed.rate, 0.55);
    },
  );
  test('speech threshold persists independently of speech speed', () async {
    final settings = await AppSettings.load();
    expect(settings.speakThreshold, 0.70);
    await settings.setSpeakThreshold(0.45);
    final restored = await AppSettings.load();
    expect(restored.speakThreshold, 0.45);
    expect(restored.speechSpeed, SpeechSpeed.normal);
    await restored.setSpeakThreshold(double.nan);
    expect(restored.speakThreshold, 0.45);
  });
}
