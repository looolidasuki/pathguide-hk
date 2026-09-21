import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_tts/flutter_tts.dart';

import 'announcer.dart';

/// 基于 `flutter_tts` 的粤语扬声器。
///
/// ## 粤语在两端不是一回事
///
/// - **Android**：`yue-HK` 需要系统装了粤语音包；很多国行 ROM 只带
///   `zh-CN` / `zh-TW`。因此这里先查可用语言，再逐级降级。
/// - **iOS**：系统自带 `zh-HK`（粤语）语音，`yue-HK` 未必被接受，
///   所以同样要按候选列表探测。
///
/// 降级链：`yue-HK` -> `zh-HK` -> `zh-TW` -> `zh-CN`。
/// **一定要让 [resolvedLanguage] 暴露出来**：若最终落到 `zh-CN`，
/// 播报会是普通话，这必须在演示界面上写清楚，不能让人以为在念粤语。
class FlutterTtsSpeaker implements Speaker {
  FlutterTtsSpeaker({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  static const List<String> candidates = <String>[
    'yue-HK',
    'zh-HK',
    'zh-TW',
    'zh-CN',
  ];

  final FlutterTts _tts;
  bool _ready = false;
  String? _resolved;

  /// 实际生效的语言标签。null 表示尚未初始化。
  String? get resolvedLanguage => _resolved;

  /// 是否用上了真正的粤语（`yue-HK` 或 `zh-HK`）。
  bool get isCantonese =>
      _resolved == 'yue-HK' || _resolved == 'zh-HK';

  /// 初始化并选定语言。返回实际生效的语言标签（可能为 null）。
  Future<String?> initialize() async {
    if (_ready) return _resolved;

    // 播报速度刻意偏慢：视障用户听的是路况，快读会漏掉关键信息。
    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    if (Platform.isAndroid) {
      // Android 上队列模式会让后一句等前一句读完，冷却逻辑已保证不拥挤，
      // 用 QUEUE_FLUSH 让插队的 P0 能立刻打断。
      await _tts.setQueueMode(0);
    }
    if (Platform.isIOS) {
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

    for (final c in candidates) {
      final exact = available.isEmpty ||
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

    // 全部候选都失败时退回系统默认语言，并让它显式暴露出来。
    if (_resolved == null) {
      try {
        await _tts.setLanguage('zh-CN');
        _resolved = 'zh-CN';
      } catch (_) {
        _resolved = null;
      }
    }
    _ready = true;
    return _resolved;
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
