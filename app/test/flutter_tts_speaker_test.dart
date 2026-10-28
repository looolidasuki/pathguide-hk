import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/tts/flutter_tts_speaker.dart';
import 'package:pathguide/settings/app_settings.dart';
import 'package:flutter_tts/flutter_tts.dart';

// flutter_tts 的音訊設定用 dart:io 判斷宿主；Windows 測試只記錄 API 邊界。
class _AudioSessionTts extends FlutterTts {
  IosTextToSpeechAudioCategory? category;
  int playbackConfigurations = 0;
  @override
  Future<dynamic> setIosAudioCategory(
    IosTextToSpeechAudioCategory category,
    List<IosTextToSpeechAudioCategoryOptions> options, [
    IosTextToSpeechAudioMode mode = IosTextToSpeechAudioMode.defaultMode,
  ]) async {
    this.category = category;
    playbackConfigurations++;
    return 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  var available = <String>['zh-HK', 'yue-HK', 'zh-TW', 'zh-CN'];
  final rejected = <String>{};
  var completeSpeech = true;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
    rejected.clear();
    completeSpeech = true;
    available = <String>['zh-HK', 'yue-HK', 'zh-TW', 'zh-CN'];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'speak' && completeSpeech) {
            scheduleMicrotask(() {
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .handlePlatformMessage(
                    'flutter_tts',
                    const StandardMethodCodec().encodeMethodCall(
                      const MethodCall('speak.onComplete'),
                    ),
                    (_) {},
                  );
            });
          }
          if (call.method == 'getLanguages') return available;
          if (call.method == 'setLanguage' &&
              rejected.contains(call.arguments)) {
            return 0;
          }
          return 1;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  test(
    'iOS selects zh-HK first and configures the shared audio session',
    () async {
      final tts = _AudioSessionTts();
      final speaker = FlutterTtsSpeaker(tts: tts);
      expect(await speaker.initialize(), 'zh-HK');
      expect(calls.where((c) => c.method == 'setSharedInstance'), isNotEmpty);
      expect(tts.category, IosTextToSpeechAudioCategory.playback);
      await speaker.speak('垃圾桶');
      expect(calls.where((c) => c.method == 'speak').single.arguments, '垃圾桶');
    },
  );

  test(
    'cached speaker restores playback before each post-recording utterance',
    () async {
      final tts = _AudioSessionTts();
      final speaker = FlutterTtsSpeaker(tts: tts);
      await speaker.initialize();
      final initial = tts.playbackConfigurations;
      for (var i = 0; i < 3; i++) {
        tts.category = IosTextToSpeechAudioCategory.playAndRecord;
        await speaker.speak('牛腩飯48元');
        expect(tts.category, IosTextToSpeechAudioCategory.playback);
        expect(tts.playbackConfigurations, initial + i + 1);
      }
    },
  );

  test(
    'applies the configured speech rate before and after initialization',
    () async {
      final speaker = FlutterTtsSpeaker(speechRate: 0.35);

      await speaker.initialize();
      expect(
        calls.where((call) => call.method == 'setSpeechRate').first.arguments,
        0.35,
      );

      await speaker.setSpeechRate(0.55);
      expect(speaker.speechRate, 0.55);
      expect(
        calls.where((call) => call.method == 'setSpeechRate').last.arguments,
        0.55,
      );
    },
  );

  test(
    'stop releases a speaking caller even without a native cancel event',
    () async {
      completeSpeech = false;
      final speaker = FlutterTtsSpeaker();
      await speaker.initialize();
      final speaking = speaker.speak('垃圾桶');
      await Future<void>.delayed(Duration.zero);
      await speaker.stop();
      await speaking.timeout(const Duration(seconds: 1));
      expect(calls.where((call) => call.method == 'stop'), isNotEmpty);
    },
  );

  test(
    'rejected Cantonese voice falls back to another accepted Cantonese voice',
    () async {
      rejected.add('zh-HK');
      expect(await FlutterTtsSpeaker().initialize(), 'yue-HK');
    },
  );

  test(
    'no accepted language stays unavailable and never sends speech',
    () async {
      rejected.addAll(available);
      final speaker = FlutterTtsSpeaker();
      expect(await speaker.initialize(), isNull);
      expect(speaker.isCantonese, isFalse);
      await speaker.speak('垃圾桶');
      expect(calls.where((c) => c.method == 'speak'), isEmpty);
    },
  );

  test(
    'English selection and switching back choose an accepted voice',
    () async {
      available = ['en-GB', 'zh-HK'];
      final speaker = FlutterTtsSpeaker(language: AppLanguage.english);
      expect(await speaker.initialize(), 'en-GB');
      await speaker.speak('stairs');
      expect(calls.where((c) => c.method == 'speak').last.arguments, 'stairs');
      await speaker.setAppLanguage(AppLanguage.chinese);
      expect(await speaker.initialize(), 'zh-HK');
      expect(speaker.isCantonese, isTrue);
    },
  );

  test(
    'Android retains yue-HK preference and Android queue configuration',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(await FlutterTtsSpeaker().initialize(), 'yue-HK');
      expect(calls.where((c) => c.method == 'setQueueMode'), isNotEmpty);
      expect(calls.where((c) => c.method == 'setIosAudioCategory'), isEmpty);
    },
  );
}
