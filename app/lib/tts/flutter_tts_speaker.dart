import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_tts/flutter_tts.dart';

import 'announcer.dart';
import '../settings/app_settings.dart';

/// 基于 `flutter_tts` 的粤语扬声器。
///
/// ## 粤语在两端不是一回事
///
/// - **Android**：`yue-HK` 需要系统装了粤语音包；很多国行 ROM 只带
///   `zh-CN` / `zh-TW`。因此这里先查可用语言，再逐级降级。
/// - **iOS**：系统自带 `zh-HK`（粤语）语音，`yue-HK` 未必被接受，
///   所以同样要按候选列表探测。
///
/// iOS 先試 `zh-HK`，Android 先試 `yue-HK`，然後才試其他中文語音。
/// **一定要让 [resolvedLanguage] 暴露出来**：若最终落到 `zh-CN`，
/// 播报会是普通话，这必须在演示界面上写清楚，不能让人以为在念粤语。
class FlutterTtsSpeaker implements Speaker {
  FlutterTtsSpeaker({
    FlutterTts? tts,
    double speechRate = defaultSpeechRate,
    AppLanguage language = AppLanguage.chinese,
  }) : _tts = tts ?? FlutterTts(),
       // ignore: prefer_initializing_formals
       _language = language,
       _speechRate = speechRate.clamp(0.0, 1.0).toDouble();

  static const double defaultSpeechRate = 0.45;

  static const List<String> candidates = <String>[
    'yue-HK',
    'zh-HK',
    'zh-TW',
    'zh-CN',
  ];

  final FlutterTts _tts;
  double _speechRate;
  bool _ready = false;
  AppLanguage _language;
  Future<void> setAppLanguage(AppLanguage value) async {
    if (_language == value) return;
    _language = value;
    await stop();
    _resolved = null;
    _ready = false;
  }

  String? _resolved;
  Completer<void>? _pendingSpeech;

  void _finishSpeech() {
    final pending = _pendingSpeech;
    _pendingSpeech = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  /// 实际生效的语言标签。null 表示尚未初始化。
  String? get resolvedLanguage => _resolved;

  /// The rate is changed by the settings page and is retained for any later
  /// initialization, including after the app returns from the background.
  double get speechRate => _speechRate;

  Future<void> setSpeechRate(double next) async {
    _speechRate = next.clamp(0.0, 1.0).toDouble();
    if (!_ready) return;
    try {
      await _tts.setSpeechRate(_speechRate);
    } catch (_) {
      // A device without TTS must not make camera recognition unusable.
    }
  }

  /// 是否用上了真正的粤语（`yue-HK` 或 `zh-HK`）。
  bool get isCantonese => _resolved == 'yue-HK' || _resolved == 'zh-HK';

  /// 初始化并选定语言。返回实际生效的语言标签（可能为 null）。
  Future<String?> initialize() async {
    if (_ready) return _resolved;

    // The saved app preference is applied before selecting a language, so the
    // rate is already correct when the first utterance becomes available.
    await _tts.setSpeechRate(_speechRate);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    // iOS flutter_tts does not complete its awaitSpeakCompletion result on
    // cancellation. Track completion here so Pause always releases the caller.
    _tts.setCompletionHandler(_finishSpeech);
    _tts.setCancelHandler(_finishSpeech);
    _tts.setErrorHandler((message) {
      final pending = _pendingSpeech;
      _pendingSpeech = null;
      if (pending != null && !pending.isCompleted) {
        pending.completeError(StateError(message));
      }
    });
    if (defaultTargetPlatform == TargetPlatform.android) {
      // Android 上队列模式会让后一句等前一句读完，冷却逻辑已保证不拥挤，
      // 用 QUEUE_FLUSH 让插队的 P0 能立刻打断。
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
    try {
      final langs = await _tts.getLanguages;
      if (langs is List) {
        available = langs.map((e) => e.toString()).toList();
      }
    } catch (_) {
      // 拿不到语言列表时仍尝试直接设置，某些 ROM 不实现该查询。
    }

    final ordered = _language == AppLanguage.english
        ? const <String>['en-HK', 'en-GB', 'en-US']
        : defaultTargetPlatform == TargetPlatform.iOS
        ? const <String>['zh-HK', 'yue-HK', 'zh-TW', 'zh-CN']
        : candidates;
    for (final c in ordered) {
      final exact =
          available.isEmpty ||
          available.any((l) => l.toLowerCase() == c.toLowerCase());
      if (!exact) continue;
      try {
        final ok = await _tts.setLanguage(c);
        // flutter_tts 在部分平台返回 1 / true / null，三种都视为成功。
        if (ok == null || ok == 1 || ok == true) {
          _resolved = c;
          break;
        }
      } catch (_) {
        continue;
      }
    }

    // 所有候選都不獲接受時保持不可用，避免把失敗誤報為普通話語音。
    _ready = true;
    return _resolved;
  }

  @override
  Future<void> speak(String text) async {
    if (!_ready) await initialize();
    if (_resolved == null) return;
    // Recording temporarily changes the shared iOS audio session. Restore it on
    // every utterance, including when language initialization was cached.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _tts.setSharedInstance(true);
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        <IosTextToSpeechAudioCategoryOptions>[
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        ],
      );
    }
    _finishSpeech();
    final pending = Completer<void>();
    _pendingSpeech = pending;
    try {
      await Future.wait<void>([
        _tts.speak(text).then((result) {
          if (result == 0) throw StateError('語音服務未接受播報');
        }),
        pending.future,
      ], eagerError: true);
    } finally {
      if (identical(_pendingSpeech, pending)) _pendingSpeech = null;
    }
  }

  @override
  Future<void> stop() async {
    _finishSpeech();
    try {
      await _tts.stop();
    } catch (_) {
      // 停止失败不影响后续播报。
    }
  }

  @override
  Future<List<String>> languages() async {
    try {
      final langs = await _tts.getLanguages;
      if (langs is List) return langs.map((e) => e.toString()).toList();
    } catch (_) {
      // 忽略：调用方只需知道「拿不到」。
    }
    return const <String>[];
  }
}
