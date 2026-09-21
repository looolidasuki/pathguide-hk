import 'dart:async';

import '../vision/detection.dart';
import '../vision/labels.dart';
/// 真正发声的接口。抽出来是为了让 [Announcer] 的取舍逻辑能被单测覆盖——
/// 播报判定的 bug（该说的没说、不该说的重复说）在真机上极难复现和定位。
abstract class Speaker {
  Future<void> speak(String text);
  Future<void> stop();

  /// 可用语言标签，用于确认粤语包是否存在。
  Future<List<String>> languages();
}

/// 什么都说不做的扬声器，供桌面调试与测试使用。
class NullSpeaker implements Speaker {
  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<List<String>> languages() async => const <String>[];
}

/// 一条待播报记录，供 UI 与测试观察。
class Announcement {
  const Announcement({
    required this.label,
    required this.score,
    required this.text,
    required this.at,
    required this.reason,
  });

  final Label label;
  final double score;
  final String text;
  final DateTime at;

  /// 为什么播报（或为什么不播报）。写进 UI 便于现场解释，
  /// 也是答辩时证明「防抖真的在干活」的证据。
  final String reason;
}

/// 播报调度器：两级冷却 + 优先级插队。
///
/// ## 为什么要两级冷却
///
/// 相机每秒几十帧，同一个垃圾桶会在连续很多帧里被检出。只有单级冷却时：
/// - 冷却太短 -> 同一个桶被反复念，用户听不到别的东西；
/// - 冷却太长 -> 真正的新障碍物被压掉。
///
/// 所以分成「**同一个类** 的冷却」与「**全局** 的冷却」两级：
/// 前者防止同一目标刷屏，后者保证话不被切碎（一句播报还没说完就换下一句）。
///
/// ## 优先级
///
/// `P0`（可能危险：台阶、楼梯、天桥入口等）可以**插队**并打断当前播报；
/// `P1`（信息类：垃圾桶、单车等）在全局冷却内**直接丢弃**而不是排队——
/// 排队会让播报越来越滞后于眼前的画面，比不说更危险。
class Announcer {
  Announcer({
    required Speaker speaker,
    this.perClassCooldown = const Duration(seconds: 2),
    this.globalCooldown = const Duration(seconds: 5),
    DateTime Function()? clock,
    // prefer_initializing_formals 建议改成 `required this._speaker`，
    // 但那会把下划线私有名暴露成公开参数标签，宁可保留显式赋值。
    // ignore: prefer_initializing_formals
  })  : _speaker = speaker,
        _clock = clock ?? DateTime.now;

  final Speaker _speaker;

  /// 同一个类别的重复播报冷却。
  final Duration perClassCooldown;

  /// 任意两次播报之间的最小间隔。
  final Duration globalCooldown;

  final DateTime Function() _clock;

  final Map<int, DateTime> _lastByClass = <int, DateTime>{};
  DateTime? _lastAny;

  /// 已播报历史（保留最近 50 条），供 UI 展示。
  final List<Announcement> history = <Announcement>[];

  /// 最近一次播报的完成 future。
  ///
  /// 对外暴露它有两个必要理由：
  /// 1. **可测试**：`_speak` 是异步的，`onFrame` 返回时 Speaker 还没被调用，
  ///    测试若立刻断言就会看到空列表（本项目实际踩过）；
  /// 2. 调用方需要知道「上一句说完了没有」才能决定是否打断。
  Future<void>? get lastSpeech => _lastSpeech;
  Future<void>? _lastSpeech;

  bool _speaking = false;
  bool get isSpeaking => _speaking;

  /// 是否启用播报。关掉后仍会记录「本该播报」的决策，便于演示防抖逻辑。
  bool enabled = true;

  /// 处理一帧检测结果，决定是否播报。
  ///
  /// 返回值是**本帧实际发起播报**的那一条（没有则为 null）。
  /// 判定顺序：类别可播报 -> 同类冷却 -> 全局冷却 -> 优先级裁决。
  Announcement? onFrame(List<Detection> detections, {bool force = false}) {
    if (detections.isEmpty) return null;

    // 按分数取最高的若干个候选，再按播报优先级排序。
    final candidates = detections
        .map((d) => (detection: d, label: labelOf(d.id)))
        .where((c) => c.label != null && c.label!.announced)
        .toList()
      ..sort((a, b) {
        final pa = _rank(a.label!);
        final pb = _rank(b.label!);
        if (pa != pb) return pa.compareTo(pb);
        return b.detection.score.compareTo(a.detection.score);
      });

    final now = _clock();
    for (final c in candidates) {
      final label = c.label!;
      final reason = _rejectReason(label, now, force);
      if (reason != null) {
        _record(label, c.detection.score, '-', now, '跳过：$reason');
        continue;
      }
      final text = announceTextFor(label);
      _lastByClass[label.id] = now;
      _lastAny = now;
      _record(label, c.detection.score, text, now, force ? '强制播报' : '正常播报');
      // 记下 future 供调用方/测试等待。不 await 是刻意的：onFrame 由相机
      // 帧回调调用，阻塞它会让掉帧；但必须让「说完了」这件事可被观察。
      _lastSpeech = _speak(text, interrupt: _isP0(label));
      return history.last;
    }
    return null;
  }

  String? _rejectReason(Label label, DateTime now, bool force) {
    if (force) return null;
    final last = _lastByClass[label.id];
    if (last != null && now.difference(last) < perClassCooldown) {
      return '同类冷却未过';
    }
    final any = _lastAny;
    if (any != null && now.difference(any) < globalCooldown) {
      return '全局冷却未过';
    }
    return null;
  }

  static bool _isP0(Label label) => label.priority == 'P0';

  /// 排序权重：P0 先，其次 P1，最后其余。与 `kAnnouncementOrder` 同源。
  static int _rank(Label label) => switch (label.priority) {
        'P0' => 0,
        'P1' => 1,
        _ => 2,
      };

  void _record(
    Label label,
    double score,
    String text,
    DateTime at,
    String reason,
  ) {
    history.add(Announcement(
      label: label,
      score: score,
      text: text,
      at: at,
      reason: reason,
    ));
    if (history.length > 50) history.removeAt(0);
  }

  Future<void> _speak(String text, {required bool interrupt}) async {
    if (!enabled) return;
    _speaking = true;
    try {
      if (interrupt) await _speaker.stop();
      await _speaker.speak(text);
    } finally {
      _speaking = false;
    }
  }

  /// 清空冷却状态。切换视频/重新开始时用，否则新场景的第一个目标
  /// 会被上一个场景遗留的冷却压掉。
  void reset() {
    _lastByClass.clear();
    _lastAny = null;
    history.clear();
    _lastSpeech = null;
  }
}

/// 一个类别的播报话术。
///
/// 直接念 `name_zh`（繁体，与香港路牌用字一致）。刻意**不**加修饰语：
/// 视障用户最需要的是「是什么 + 在哪」，修饰语会拖长播报时间，
/// 而播报延迟在这里等于危险。方位（左/右/前）应由导航层算完再拼进来，
/// 检测层不知道用户朝向，自己猜会给出错误方位。
String announceTextFor(Label label) => label.nameZh;
