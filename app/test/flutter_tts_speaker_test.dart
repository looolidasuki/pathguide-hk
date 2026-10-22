// 移植自上游 `actiondarr/pathguide` 的 `app/test/flutter_tts_speaker_test.dart`
// （2026-10-20）。移植時改了**三處**，每一處都是因為本倉庫的契約本來就不同，
// 不是為了讓測試變綠：
//
// 1. **語速不可配置**：本倉庫沒有設定頁（見
//    `docs/UPSTREAM-MERGE-ASSESSMENT.md` §5.3，刻意不引入 `shared_preferences`），
//    語速固定在 `initialize()` 內寫死 0.45。所以上游那條「可設定語速」改成
//    「固定語速必須在 initialize 時被套用」——鎖住真正存在的那個行為。
//
// 2. **候選語言由系統 locale 決定**：上游偏好粵語；本倉庫 `_candidatesForSystem()`
//    是「系統地區優先，英文永遠墊底」（zh-CN 必須先試 zh-CN，不能直接跳 yue-HK）。
//    因此測試要注入 locale 才能驗證順序——這也順帶補上了
//    `FlutterTtsSpeaker(systemLocale:)` 這個可測性接縫。
//
// 3. **粵語全被拒時退回英文並照樣發聲**：上游選擇「保持不可用、絕不發聲」；
//    本倉庫選擇**發聲**並由 `demo_page.dart` 播一句 `ttsFallbackWarning`。
//    理由是「靜默」正是本專案反覆吃虧的那類失敗：使用者分不出
//    「沒東西要唸」與「壞了」。這裡斷言的是本倉庫的選擇。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/tts/announcer.dart';
import 'package:pathguide/tts/flutter_tts_speaker.dart';
import 'package:pathguide/vision/vision_session.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 只為了攔 `setIosAudioCategory`，把實際設定的 category 記下來。
///
/// flutter_tts 的音訊設定用 `dart:io` 判斷宿主；在 Windows 上跑測試只驗 API 邊界。
class _AudioSessionTts extends FlutterTts {
  IosTextToSpeechAudioCategory? category;
  List<IosTextToSpeechAudioCategoryOptions>? options;

  @override
  Future<dynamic> setIosAudioCategory(
    IosTextToSpeechAudioCategory category,
    List<IosTextToSpeechAudioCategoryOptions> options, [
    IosTextToSpeechAudioMode mode = IosTextToSpeechAudioMode.defaultMode,
  ]) async {
    this.category = category;
    this.options = options;
    return 1;
  }
}

/// 非 `FlutterTtsSpeaker` 的 `Speaker` 假實現。
///
/// 只為了證明 `VisionSession.applySpeechRate` 遇到「不是真 TTS」的 speaker 時
/// **既不拋出、也不亂叫**：`Speaker` 介面刻意沒有語速方法
/// （見 `app/lib/tts/announcer.dart`），所以這條分支必須是安靜的 no-op，
/// 而不是「漏接的例外」。
class _FakeSpeaker implements Speaker {
  final List<String> calls = <String>[];

  @override
  Future<String?> initialize() async {
    calls.add('initialize');
    return null;
  }

  @override
  Future<void> speak(String text) async {
    calls.add('speak');
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
  }

  @override
  Future<List<String>> languages() async {
    calls.add('languages');
    return const <String>[];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  var available = <String>[];
  final rejected = <String>{};

  FlutterTtsSpeaker speakerFor(
    Map<String, Object?> options, {
    FlutterTts? tts,
    Locale locale = const Locale('zh', 'HK'),
  }) {
    available = (options['available'] as List<String>?) ?? <String>[];
    return FlutterTtsSpeaker(
      tts: tts,
      systemLocale: () => locale,
    );
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
    rejected.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'getLanguages') return available;
      if (call.method == 'setLanguage' && rejected.contains(call.arguments)) {
        // flutter_tts 的約定：0 表示這個語言包不可用。
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

  List<Object?> argsOf(String method) =>
      calls.where((c) => c.method == method).map((c) => c.arguments).toList();

  test('★ 系統 zh-HK：首選粵語，並設好 iOS 共享音訊 session', () async {
    final tts = _AudioSessionTts();
    final speaker = speakerFor(
      {'available': ['zh-HK', 'yue-HK', 'zh-TW', 'zh-CN', 'en-US']},
      tts: tts,
    );

    expect(await speaker.initialize(), 'zh-HK');
    expect(speaker.isCantonese, isTrue);

    // 「只播不改別人音樂」的 session 設定漏了會出現兩種壞法：
    // 靜音鍵把導航語音一起關掉，或導航語音把使用者的音樂停掉。
    expect(argsOf('setSharedInstance'), isNotEmpty);
    expect(tts.category, IosTextToSpeechAudioCategory.playback);
    expect(
      tts.options,
      contains(IosTextToSpeechAudioCategoryOptions.mixWithOthers),
    );

    await speaker.speak('垃圾桶');
    expect(argsOf('speak'), <Object?>['垃圾桶']);
  });

  test('★ 系統 zh-CN：先普通話，不得直接跳到粵語', () async {
    final speaker = speakerFor(
      {'available': ['zh-CN', 'zh-HK', 'yue-HK', 'en-US']},
      locale: const Locale('zh', 'CN'),
    );

    expect(await speaker.initialize(), 'zh-CN');
    // 「有粵語就用粵語」聽起來貼心，但對普通話使用者就是聽不懂。
    expect(speaker.isCantonese, isFalse);
  });

  test('zh-HK 被拒時退到下一個可用的粵語（yue-HK）', () async {
    // 候選清單同時包含 `zh-HK` 與 `zh_HK` 兩種寫法（不同引擎認不同的形式），
    // 所以要退到 yue-HK，這兩種寫法都得被拒——這是實測出來的細節，不是猜的。
    rejected.addAll(<String>['zh-HK', 'zh_HK']);
    final speaker = speakerFor(
      {'available': ['zh-HK', 'yue-HK', 'en-US']},
    );

    expect(await speaker.initialize(), 'yue-HK');
    expect(speaker.isCantonese, isTrue);
  });

  test('★ 粵語全被拒：退回英文並**照樣發聲**，不靜默', () async {
    rejected.addAll(<String>[
      'zh-HK', 'zh_HK', 'yue-HK', 'zh-TW', 'zh-TW_', 'zh-CN', 'zh', 'yue',
    ]);
    final speaker = speakerFor(
      {'available': ['zh-HK', 'yue-HK', 'zh-TW', 'zh-CN', 'en-US']},
    );

    expect(await speaker.initialize(), 'en-US');
    expect(speaker.isCantonese, isFalse);

    await speaker.speak('垃圾桶');
    // 本倉庫的選擇是「用錯語言唸」而不是「不唸」：相對應的提示由
    // demo_page 的 ttsFallbackWarning 播給使用者。
    expect(argsOf('speak'), <Object?>['垃圾桶']);
    expect(speaker.lastSpeechError, isNull);
  });

  test('語速固定在 initialize 套用（本倉庫沒有設定頁，不提供可調語速）', () async {
    final speaker = speakerFor(
      {'available': ['zh-HK', 'en-US']},
    );

    await speaker.initialize();
    final rates = argsOf('setSpeechRate');
    expect(rates, isNotEmpty, reason: '語速必須在初始化時就設定，不能等第一次播報');
    expect(rates.first, 0.45);
  });

  test('Android：設佇列模式，且不碰 iOS 的音訊分類', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final speaker = speakerFor(
      {'available': ['yue-HK', 'zh-HK', 'en-US']},
    );

    // 系統是 zh-HK，所以**精確匹配的 zh-HK 先於 yue-HK**——
    // 這與上游實作（一律先試粵語）不同，是本倉庫「系統地區優先」的規則。
    expect(await speaker.initialize(), 'zh-HK');
    // queueMode(0) 讓多句依序唸完並自然停頓——這是「逐句唸」的前提。
    expect(argsOf('setQueueMode'), isNotEmpty);
    expect(argsOf('setIosAudioCategory'), isEmpty);
    expect(argsOf('setSharedInstance'), isEmpty);
  });

  test('speak 前沒初始化會自己初始化（首次啟動 TTS 引擎可能還沒就緒）', () async {
    final speaker = speakerFor(
      {'available': ['zh-HK', 'en-US']},
    );

    await speaker.speak('前面有樓梯');
    expect(argsOf('speak'), <Object?>['前面有樓梯']);
    expect(speaker.resolvedLanguage, 'zh-HK');
  });

  // 語速改由設定頁（`settings/app_settings.dart`）決定之後，上面那條
  // 「固定 0.45」不再是唯一事實：注入的值必須真的走到 TTS 引擎。
  test('建構時給的語速會在 initialize 被套用', () async {
    final speaker = FlutterTtsSpeaker(
      systemLocale: () => const Locale('zh', 'HK'),
      speechRate: 0.35,
    );
    await speaker.initialize();
    expect(
      calls.where((c) => c.method == 'setSpeechRate').first.arguments,
      0.35,
    );
  });

  test('setSpeechRate 會立刻套用並記住', () async {
    final speaker = FlutterTtsSpeaker(systemLocale: () => const Locale('zh', 'HK'));
    await speaker.initialize();
    await speaker.setSpeechRate(0.55);
    expect(speaker.speechRate, 0.55);
    expect(
      calls.where((c) => c.method == 'setSpeechRate').last.arguments,
      0.55,
    );
  });

  // 建構子的 `speechRate:` 是**唯一的啟動注入路徑**（設定檔裡持久化的值），
  // 而它正好是首次 `initialize()` 會直接送進引擎的那個數。若只有 `setSpeechRate`
  // 夾、建構子不夾，一個越界的存檔值就會在啟動流程裡原封不動地進引擎——
  // 也就是說，兩條路徑必須共用同一個 clamp（這裡就是在釘住這件事）。
  test('建構子的越界語速會被夾回合法區間', () async {
    final tooFast = FlutterTtsSpeaker(
      systemLocale: () => const Locale('zh', 'HK'),
      speechRate: 5.0,
    );
    expect(tooFast.speechRate, 1.0, reason: '上界 1.0，不是原封不動的 5.0');
    await tooFast.initialize();
    expect(
      calls.where((c) => c.method == 'setSpeechRate').last.arguments,
      1.0,
    );

    final tooSlow = FlutterTtsSpeaker(
      systemLocale: () => const Locale('zh', 'HK'),
      speechRate: -1,
    );
    expect(tooSlow.speechRate, 0.1, reason: '下界 0.1，不是原封不動的 -1');
    await tooSlow.initialize();
    expect(
      calls.where((c) => c.method == 'setSpeechRate').last.arguments,
      0.1,
    );
  });

  // 有些平台在 `initialize()` 之前就拒絕 `setSpeechRate`。那條路徑接在
  // 「讀設定檔」之後，而使用者（尤其全盲使用者）的啟動流程絕不能被一個
  // 偏好設定擋死：引擎拒絕 → 記進 lastSpeechError，**不往外拋**。
  test('setSpeechRate 被引擎拒絕時不拋出，只記下錯誤', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'getLanguages') return available;
      if (call.method == 'setSpeechRate') {
        throw PlatformException(code: 'engine_not_ready');
      }
      return 1;
    });

    final speaker = FlutterTtsSpeaker(systemLocale: () => const Locale('zh', 'HK'));

    // `completes` 本身就是「不拋」的斷言：若 try/catch 被拿掉，這裡會紅。
    await expectLater(speaker.setSpeechRate(0.55), completes);
    // 值仍然記住了：引擎這次不認，但下一次 `initialize()` 會再送一次。
    expect(speaker.speechRate, 0.55);
    expect(speaker.lastSpeechError, isNotNull, reason: '失敗要留痕跡，不能靜默');
    expect(speaker.lastSpeechError, contains('語速'));
  });

  // ── VisionSession.applySpeechRate ────────────────────────────────────────
  // 這條分支（`speaker is FlutterTtsSpeaker`）在 Task 2 落地時完全沒有測試。
  // 它唯一會壞的方式是「看起來有接、其實沒接」，而那在真機上只表現成
  // 「拉了語速沒反應」——最難回報、也最難怪到這一行的那種壞法。
  test('VisionSession.applySpeechRate 真的把語速送進 FlutterTtsSpeaker', () async {
    final speaker = FlutterTtsSpeaker(systemLocale: () => const Locale('zh', 'HK'));
    final session = VisionSession(speaker: speaker);

    await session.applySpeechRate(0.35);

    expect(speaker.speechRate, 0.35);
    expect(
      calls.where((c) => c.method == 'setSpeechRate').last.arguments,
      0.35,
    );
  });

  test('VisionSession.applySpeechRate 對非 FlutterTtsSpeaker 安靜略過、不拋出', () async {
    final fake = _FakeSpeaker();
    final session = VisionSession(speaker: fake);

    // 若型別檢查被寫成無條件轉型，這一行就會拋 `_TypeError` 而不是完成。
    await expectLater(session.applySpeechRate(0.55), completes);

    // 「略過」是刻意的（語速只對真 TTS 有意義），而且必須是完全的 no-op：
    // 連 speak/stop 都不該被連帶觸發。
    expect(fake.calls, isEmpty);
  });
}
