import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;

import '../tts/announcer.dart';
import '../tts/flutter_tts_speaker.dart';
import '../vision/platform_vision.dart';
import '../vision/vision_source.dart';

/// 相機與語音的**共用持有者**，跨兩個模式存活。
///
/// ## 為什麼要有這一層（而不是每個畫面各自開相機）
///
/// App 有兩個模式：**引導**與**讀字**。若每個畫面各自建構相機與語音，
/// 切換模式就必須「停舊的、起新的」，而真機實測相機啟動要 1–2 秒——
/// 使用者每次切換都要等一片黑。
///
/// 所以把相機與語音的生命週期拉高到畫面之上：
///
/// ```
/// HomePage（選模式）
///   └─ VisionSession（相機 + 語音，跨模式存活）
///        ├─ DemoPage（引導模式）：訂閱 frames，跑偵測與障礙物播報
///        └─ TextReadPage（讀字模式）：輪詢 readText()，唸文字
/// ```
///
/// ## 模式之間是**互斥**的，這是刻意的
///
/// 真機上兩者會互相搶：
///
/// - **CPU**：讀字一次 0.6–2.0 秒（1280×960），而偵測一次 197 ms。
///   同時跑的話讀字只能擠在偵測空檔，而且常常讀不到。
/// - **語音**：實測 `spotDeferred` 佔一半——招牌被障礙物播報讓位丟掉，
///   而且永遠不會補唸。
///
/// 所以進入某個模式時，**只有那個模式的輸出在跑**。這也讓「讀字」可以
/// 打斷障礙物播報——因為讀字時根本沒有障礙物播報。
class VisionSession {
  VisionSession({
    Speaker? speaker,
    VisionSource Function()? sourceFactory,
  })  : speaker = speaker ?? FlutterTtsSpeaker(),
        // prefer_initializing_formals 建議 `_sourceFactory` 也改成
        // `this._sourceFactory`，但那會把底線私有名暴露成公開參數標籤
        // （呼叫端要寫 `_sourceFactory:`），寧可保留顯式賦值。
        // ignore: prefer_initializing_formals
        _sourceFactory = sourceFactory;

  /// 語音輸出。兩個模式共用同一個（TTS 引擎本來就是全域資源）。
  final Speaker speaker;

  final VisionSource Function()? _sourceFactory;

  VisionSource? _source;
  VisionSource? get source => _source;

  /// 相機是否已就緒。
  bool get ready => _source != null;

  /// 障礙物播報器。**只給引導模式用**；讀字模式不碰它。
  late final Announcer announcer = Announcer(speaker: speaker);

  /// 建立並啟動相機。已有相機時直接回傳現有的（不重啟）。
  ///
  /// 回傳的是「相機是否可用」的說明，失敗時帶可操作的原因。
  Future<VisionSourceStatus> ensureCamera() async {
    final existing = _source;
    if (existing != null) {
      return VisionSourceStatus(ok: true, message: '相機已在運作');
    }
    final src = _makeSource();
    _source = src;
    final status = await src.initialize();
    if (!status.ok) {
      // 起不來就別留著半死的來源：留著會讓下一次 ensureCamera 以為可用。
      _source = null;
      await src.dispose();
    }
    return status;
  }

  VisionSource _makeSource() {
    final injected = _sourceFactory;
    if (injected != null) return injected();
    // iOS VisionPlugin 在原生侧把帧旋成竖屏（rotationDegrees=0）；
    // Android CameraX 仍输出横屏帧，需按 90° 推出正立坐标系。
    // 這個平台量集中在這裡，畫面不必各自判斷。
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    return PlatformVision(rotationDegrees: isIos ? 0 : 90);
  }

  /// 目前是不是真的原生相機（讀字需要它；桌面的假來源沒有 readText）。
  PlatformVision? get platform =>
      _source is PlatformVision ? _source as PlatformVision : null;

  /// 放掉相機。離開 App、或使用者明確要關閉時呼叫。
  Future<void> releaseCamera() async {
    final src = _source;
    _source = null;
    if (src == null) return;
    try {
      await src.dispose();
    } catch (_) {
      // 釋放失敗不該擋住流程；真機上 dispose 偶爾會卡（見 _stopGuidance 的說明）。
    }
  }

  /// 唸一句話，**繞過**任何冷卻。
  ///
  /// 用於「使用者剛按了什麼」這類即時回饋。刻意與 [Announcer] 分開：
  /// 那套冷卻/讓位規則只服務障礙物播報。
  void say(String text) {
    if (text.trim().isEmpty) return;
    speaker.speak(text).ignore();
  }

  /// 停止目前的發聲（切模式、離開畫面時用）。
  Future<void> stopSpeaking() async {
    try {
      await speaker.stop();
    } catch (_) {
      // 同上，不擋流程。
    }
  }

  /// 套用播報語速。**只對真正的 TTS 生效**。
  ///
  /// 為什麼不在 [Speaker] 介面上加方法：那會讓每一個測試假實現都要跟著改，
  /// 而語速只跟真實 TTS 有關。所以換成別的 Speaker 實作時這裡**安靜地什麼都不做**——
  /// 不是漏了，是刻意的（語速對 `NullSpeaker` 這種假實現沒有意義）。
  ///
  /// 失敗也不往外拋：這條路徑接在「讀設定檔」之後，而啟動流程絕不能被一個
  /// 無關緊要的偏好設定擋死（同 [stopSpeaking]）。
  Future<void> applySpeechRate(double rate) async {
    final s = speaker;
    if (s is! FlutterTtsSpeaker) return;
    try {
      await s.setSpeechRate(rate);
    } catch (_) {
      // 語速套不上只是「聽起來不是他選的速度」，不該讓設定載入失敗。
    }
  }

  /// 測試用：直接指定來源，跳過真正的相機啟動。
  @visibleForTesting
  void useSourceForTest(VisionSource src) {
    _source = src;
  }
}
