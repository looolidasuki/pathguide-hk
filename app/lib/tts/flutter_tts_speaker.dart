import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

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
  FlutterTtsSpeaker({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
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
  Future<String?> initialize() async {
    if (_ready) return _resolved;

    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _tts.setQueueMode(0);
    }
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
    final locale = PlatformDispatcher.instance.locale;
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

  @override
  Future<void> speak(String text) async {
    if (!_ready) await initialize();
    if (_resolved == null) return;
    await _tts.speak(text);
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
