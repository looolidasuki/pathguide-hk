import 'dart:async';

import '../vision/detection.dart';
import '../vision/labels.dart';

/// Default speech confidence threshold, independently adjustable from drawing.
/// 0.70 is a legacy default from the old bin model. It has not been calibrated
/// for the nine-class model and is not a probability of correctness.
const double kMinSpeakScore = 0.70;

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

/// Select a short summary from the latest frame; never queue camera results.
/// New classes bypass the repeat cooldown. An in-flight utterance finishes
/// before another frame is considered, so results cannot interrupt each other.
class Announcer {
  Announcer({
    required Speaker speaker,
    this.perClassCooldown = const Duration(seconds: 5),
    this.globalCooldown = const Duration(seconds: 5),
    this.minSpeakScore = kMinSpeakScore,
    this.maxLabelsPerAnnouncement = 3,
    DateTime Function()? clock,
    // prefer_initializing_formals 建议改成 `required this._speaker`，
    // 但那会把下划线私有名暴露成公开参数标签，宁可保留显式赋值。
    // ignore: prefer_initializing_formals
  }) : _speaker = speaker,
       _clock = clock ?? DateTime.now;

  final Speaker _speaker;

  /// 同一个类别的重复播报冷却。
  final Duration perClassCooldown;

  /// Repeat pacing; a newly observed class bypasses this interval.
  final Duration globalCooldown;
  final int maxLabelsPerAnnouncement;

  /// 低于此分数的检出**不播报**（仍会画在屏幕上）。见 [kMinSpeakScore]。
  double minSpeakScore;

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
  bool _enabled = true;
  int _speechGeneration = 0;
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (!value && _enabled) ++_speechGeneration;
    _enabled = value;
  }

  /// 处理一帧检测结果，决定是否播报。
  ///
  /// 返回值是**本帧实际发起播报**的那一条（没有则为 null）。
  /// 判定顺序：类别可播报 -> 同类冷却 -> 全局冷却 -> 优先级裁决。
  Announcement? onFrame(List<Detection> detections, {bool force = false}) {
    if (detections.isEmpty || _speaking) return null;

    // 按分数取最高的若干个候选，再按播报优先级排序。
    final candidates =
        detections
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
    final selected = <({Detection detection, Label label})>[];
    final seen = <int>{};
    for (final c in candidates) {
      final label = c.label!;
      if (!seen.add(label.id)) continue;
      final reason = _rejectReason(label, c.detection.score, now, force);
      if (reason != null) {
        _record(label, c.detection.score, '-', now, '跳過：$reason');
        continue;
      }
      selected.add((detection: c.detection, label: label));
      if (selected.length >= maxLabelsPerAnnouncement) break;
    }
    if (selected.isEmpty) return null;
    final text = selected.map((c) => announceTextFor(c.label)).join('、');
    for (final c in selected) {
      _lastByClass[c.label.id] = now;
      _record(c.label, c.detection.score, text, now, force ? '強制播報' : '正常播報');
    }
    _lastAny = now;
    _lastSpeech = _speak(text);
    return history.last;
  }

  String? _rejectReason(Label label, double score, DateTime now, bool force) {
    // ★ 分数门槛先判，且**不受 force 影响**。
    //
    // 这一点是刻意的：`force` 的语义是「这次不要被冷却挡住」（演示与测试用），
    // 属于**时机**问题；而分数门槛管的是「这个东西到底是不是真的」，
    // 属于**正确性**问题。让 force 绕过它，等于给了一个「逢低分也照念」的后门，
    // 而那正是要防的事。
    if (!score.isFinite || score > 1 || score < minSpeakScore) {
      return '分數 ${score.toStringAsFixed(2)} 低於播報門檻 '
          '${minSpeakScore.toStringAsFixed(2)}';
    }
    if (force) return null;
    final last = _lastByClass[label.id];
    if (last != null && now.difference(last) < perClassCooldown) {
      return '同類冷卻未過';
    }
    final any = _lastAny;
    if (last != null && any != null && now.difference(any) < globalCooldown) {
      return '全局冷卻未過';
    }
    return null;
  }

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
    history.add(
      Announcement(
        label: label,
        score: score,
        text: text,
        at: at,
        reason: reason,
      ),
    );
    if (history.length > 50) history.removeAt(0);
  }

  Future<void> _speak(String text) async {
    if (!enabled) return;
    final generation = _speechGeneration;
    _speaking = true;
    try {
      await _speaker.stop();
      // 暫停後即使重新啟用，也不能把上一個場景的待播語音讀出。
      if (!enabled || generation != _speechGeneration) return;
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
