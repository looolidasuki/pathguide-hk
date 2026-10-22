import 'dart:async';
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart'
  show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter_tts/flutter_tts.dart';

import '../l10n/app_locale.dart';
import 'announcer.dart';

/// TTS speaker that follows the phone system language.
///
/// Preference order:
/// 1. Exact / prefix match for the system locale (e.g. `zh-HK`, `en-US`)
/// 2. Same language family (`zh`, `en`, …)
/// 3. English (`en-US` / `en-GB` / `en`)
///
/// Never hard-code Cantonese as the only preset.
class FlutterTtsSpeaker implements Speaker {
  FlutterTtsSpeaker({
    FlutterTts? tts,
    Locale Function()? systemLocale,
    double? speechRate,
  })  : _tts = tts ?? FlutterTts(),
        _systemLocale = systemLocale ?? (() => PlatformDispatcher.instance.locale),
        _speechRate = _clampRate(speechRate ?? defaultSpeechRate);

  /// 預設語速。三檔中的「正常」（見 `settings/app_settings.dart`）。
  static const double defaultSpeechRate = 0.45;

  /// 語速合法區間的下界。低於它引擎要嘛不發聲，要嘛慢到像壞掉。
  static const double _minSpeechRate = 0.1;

  /// 語速合法區間的上界。高於它幾乎聽不出字（尤其粵語）。
  static const double _maxSpeechRate = 1.0;

  /// 把任意語速夾進合法區間。**建構子與 [setSpeechRate] 只能走這一個入口。**
  ///
  /// 為什麼一定要共用：這兩條路徑都是「外部值進入引擎」的門，而且指向同一個
  /// 引擎參數。建構子的 `speechRate:` 是**唯一的啟動注入路徑**（設定檔裡持久化的值）
  /// ——若只有 `setSpeechRate` 夾、建構子不夾，一個越界的存檔值就會原封不動地
  /// 在首次 `initialize()` 時送進引擎，而 `initialize()` 正是啟動流程本身。
  /// 共用一個 helper 之後，兩條路徑在結構上不可能各自漂移。
  ///
  /// `num.clamp` 的靜態型別是 `num`，直接賦值給 `double` 欄位會編不過（analyze 會紅），
  /// 所以要 `.toDouble()`。
  static double _clampRate(double rate) =>
      rate.clamp(_minSpeechRate, _maxSpeechRate).toDouble();

  final FlutterTts _tts;

  /// 讀取「系統語言」的接縫。
  ///
  /// 為什麼需要注入：`_candidatesForSystem()` 原本直接讀
  /// `PlatformDispatcher.instance.locale`，而那是**真實平台單例**——
  /// widget 測試裡把 `tester.binding.platformDispatcher.localeTestValue`
  /// 設成 zh-HK **不會**影響它。結果是「zh-HK 首選粵語」「zh-CN 先用普通話」
  /// 這些最關鍵的分支在測試裡一律走 en-US 那條，等於沒測。
  /// 有了這個接縫，測試才能把 locale 餵進去驗證候選順序。
  final Locale Function() _systemLocale;

  /// 目前語速。由設定頁灌進來（`speechRate:`），也可在執行時改。
  /// 原本這裡是寫死的 0.45，見 `initialize()`。
  double _speechRate;

  /// 目前語速（給測試與設定頁讀）。
  double get speechRate => _speechRate;

  /// 執行時改語速：先記住，再順手試著立刻套用。
  ///
  /// 真正的引擎設定在 `initialize()` 內（見該處），但這裡也會打一次引擎呼叫，
  /// 讓「App 已經在跑、使用者拉滑條」的情境立刻生效，不必等下一次初始化。
  ///
  /// **先呼叫也不會壞**：有些平台在 `initialize()` 之前就拒絕 `setSpeechRate`。
  /// 那種失敗**只記進 [lastSpeechError]，不會往外拋**——這條路徑接在設定載入之後，
  /// 而啟動流程是視障使用者唯一不能死的地方。記下來而不是吞掉，是為了別再製造
  /// 本專案反覆吃虧的那種「靜默失敗」。
  Future<void> setSpeechRate(double rate) async {
    _speechRate = _clampRate(rate);
    try {
      await _tts.setSpeechRate(_speechRate);
    } catch (e) {
      _lastError = 'TTS 設定語速失敗：$e';
      // ignore: avoid_print
      print('[PathGuide][TTS] $_lastError');
    }
  }

  bool _ready = false;
  String? _resolved;

  /// Active TTS BCP-47 tag. null if not initialized / unavailable.
  String? get resolvedLanguage => _resolved;

  /// True when the resolved voice is Cantonese (`yue-*` or `zh-HK`).
  bool get isCantonese {
    final tag = (_resolved ?? '').toLowerCase();
    return tag.startsWith('yue') || tag == 'zh-hk' || tag.startsWith('zh-hk');
  }

  /// Initialize and pick a voice. Returns the resolved language tag.
  @override
  Future<String?> initialize() async {
    if (_ready) return _resolved;

    await _tts.setSpeechRate(_speechRate);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _tts.setQueueMode(0);
    }
    // ★ 讓 `speak()` 等到**整句唸完**才完成。
    //
    // 沒有這一行時，`flutter_tts` 的 `speak()` 在音訊**排入佇列後立刻**就 resolve，
    // 於是 `Announcer._speaking` 立刻變回 false——**那個旗標完全反映不了實際
    // 有沒有在出聲**。後果有兩個，而且都很糟：
    //
    // 1. `canSpeakText()` 的「正在說話就別插嘴」判斷永遠不成立 → 識字會插進
    //    障礙物播報中間，把「前面有樓梯」切斷；
    // 2. 整個系統失去「現在在講話」的概念，所有讓位／打斷決策都建立在錯的前提上。
    //
    // 這是 `_speaking` 唯一能變成可信的辦法（`flutter_tts` 沒有回報播放狀態的介面）。
    await _tts.awaitSpeakCompletion(true);
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _tts.setSharedInstance(true);
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        <IosTextToSpeechAudioCategoryOptions>[
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        ],
      );
    }

    List<String> available = const <String>[];
    for (var attempt = 0; attempt < (kIsWeb ? 10 : 1); attempt++) {
      try {
        final langs = await _tts.getLanguages;
        if (langs is List) {
          available = langs.map((e) => e.toString()).toList();
        }
      } catch (_) {
        // Some devices do not expose the installed voice list.
      }
      if (available.isNotEmpty || !kIsWeb) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (kIsWeb && available.isEmpty) {
      _ready = true;
      return null;
    }

    final candidates = _candidatesForSystem();
    for (final c in candidates) {
      final exact = available.isEmpty ||
          available.any((l) => _langMatches(l, c));
      if (!exact && available.isNotEmpty) continue;
      try {
        final ok = await _tts.setLanguage(c);
        if (ok == null || ok == 1 || ok == true) {
          _resolved = c;
          break;
        }
      } catch (_) {
        continue;
      }
    }

    if (_resolved == null) {
      for (final fallback in <String>['en-US', 'en-GB', 'en']) {
        try {
          final ok = await _tts.setLanguage(fallback);
          if (ok == null || ok == 1 || ok == true) {
            _resolved = fallback;
            break;
          }
        } catch (_) {
          continue;
        }
      }
    }
    _ready = true;
    return _resolved;
  }

  /// Build TTS language candidates from the phone locale, then English.
  ///
  /// Order follows the **system** region first. Do not prefer Cantonese for
  /// every Chinese locale (e.g. `zh-CN` must try `zh-CN` before `yue-HK`).
  List<String> _candidatesForSystem() {
    final locale = _systemLocale();
    final lang = locale.languageCode.toLowerCase();
    final country = (locale.countryCode ?? '').toUpperCase();
    final script = locale.scriptCode;

    final out = <String>[];
    void add(String tag) {
      if (tag.isEmpty) return;
      if (!out.any((e) => e.toLowerCase() == tag.toLowerCase())) {
        out.add(tag);
      }
    }

    if (country.isNotEmpty) {
      add('$lang-$country');
      add('${lang}_$country');
    }
    if (script != null && script.isNotEmpty) {
      add('$lang-$script');
    }

    if (lang == 'yue' || country == 'HK' || country == 'MO') {
      add('yue-HK');
      add('zh-HK');
      add('zh-TW');
      add('zh-CN');
      add('zh');
    } else if (country == 'TW' || script == 'Hant') {
      add('zh-TW');
      add('zh-HK');
      add('zh-CN');
      add('zh');
    } else if (lang == 'zh') {
      // Mainland / generic Chinese: stay with Mandarin tags first.
      add('zh-CN');
      add('zh-TW');
      add('zh-HK');
      add('zh');
    }
    add(lang);

    // Hard fallback: English, always last.
    add('en-US');
    add('en-GB');
    add('en');

    // Keep AppLocale in sync with whatever the OS reported.
    AppLocale.current = AppLocale.resolve(locale);
    return out;
  }

  static bool _langMatches(String available, String wanted) {
    final a = available.toLowerCase().replaceAll('_', '-');
    final w = wanted.toLowerCase().replaceAll('_', '-');
    if (a == w) return true;
    if (a.startsWith('$w-') || w.startsWith('$a-')) return true;
    final aLang = a.split('-').first;
    final wLang = w.split('-').first;
    return aLang == wLang && wLang.length >= 2;
  }

  /// 最後一次發聲相關失敗的原因；null 表示沒有失敗過。
  ///
  /// 為什麼要對外露出：`speak()` 的失敗原本是**完全靜默**的（直接 `return`），
  /// 使用者聽到的是「什麼都沒有」，而我們在日誌裡也找不到任何痕跡。
  /// 這在真機上無法區分「沒觸發」與「觸發了但沒聲音」——正是本專案反覆吃虧的
  /// 那類「靜默失敗」。
  ///
  /// 語速設定失敗（[setSpeechRate]）也記在這裡：它同樣是「只影響聽起來怎樣、
  /// 不該讓流程停下來，但必須留下痕跡」的那類問題。成功發聲會把它清回 null。
  String? get lastSpeechError => _lastError;
  String? _lastError;

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;

    // 初始化失敗過就再試一次：首次啟動時 TTS 引擎可能還沒就緒，
    // 而 `_ready` 一旦為 true 就再也不會重新初始化，於是整個 session 都啞掉。
    if (!_ready) await initialize();

    if (_resolved == null) {
      _lastError ??= 'TTS 沒有可用語音（initialize 未挑到語言包）→ 靜默無聲';
      // ignore: avoid_print
      print('[PathGuide][TTS] 丟棄播報（無可用語音）：'
            '${text.length > 20 ? '${text.substring(0, 20)}…' : text}');
      return;
    }

    try {
      await _tts.speak(text);
      _lastError = null;
    } catch (e) {
      _lastError = 'TTS 發聲失敗：$e';
      // ignore: avoid_print
      print('[PathGuide][TTS] $_lastError');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Ignore stop failures.
    }
  }

  @override
  Future<List<String>> languages() async {
    try {
      final langs = await _tts.getLanguages;
      if (langs is List) return langs.map((e) => e.toString()).toList();
    } catch (_) {
      // Caller only needs to know lookup failed.
    }
    return const <String>[];
  }
}
