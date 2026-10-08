import 'dart:async';

import '../l10n/app_locale.dart';
import '../l10n/app_strings.dart';
import '../vision/detection.dart';
import '../vision/labels.dart';

/// 播报所需的**最低置信度**，与「显示门槛」是两件事。
///
/// ## 为什么必须比显示门槛更严
///
/// 两者代价完全不对称：
///
/// - **显示**（界面那根滑条，默认 0.30）只是屏幕上多画一个框，代价接近零；
/// - **播报**是说给视障用户听的。误报会让用户**对空无一物做出动作**——
///   在马路牙子上、在楼梯口前，这是安全问题，不只是烦人。
///
/// 漏报的代价则被**帧的重复**摊薄了：一个真实存在的垃圾桶会在连续很多帧里
/// 被检出，某一帧分数不够而没念，下一帧（冷却过后）还有机会；
/// 而误报只要**一帧**就足以被念出去。所以这个门槛应当按**精度**来定，
/// 而不是按 precision/recall 的折中点——召回在时间维度上会自己长回来。
///
/// ## 0.70 这个数是怎么来的（不是拍脑袋）
///
/// `scripts/pick_speak_threshold.py` 在 44 张带人工标注的实拍图上跑全链路，
/// 把检出按分数与标注配对比对（`data/dataset`，`bin` 单类）：
///
/// | 门槛 | 说出条数 | 误报 | 精度 | 召回 |
/// |---|---|---|---|---|
/// | 0.30（= 显示默认值） | 92 | 8 | 0.913 | 0.689 |
/// | 0.50 | 86 | 5 | 0.942 | 0.664 |
/// | **0.70** | **78** | **3** | **0.962** | **0.615** |
/// | 0.90 | 62 | 0 | 1.000 | 0.508 |
///
/// 取 0.70：误报从 8 条降到 3 条（**减少 62%**），而每帧召回只掉 0.07——
/// 后者还会被多帧重复与冷却后的重播补回来。
///
/// ## 改模型之后要重算
///
/// 这个值绑定当前模型。换了模型或改了导出方式以后，
/// 重跑 `scripts/pick_speak_threshold.py` 再改这里，不要沿用旧值。
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
    this.minSpeakScore = kMinSpeakScore,
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

  /// 低于此分数的检出**不播报**（仍会画在屏幕上）。见 [kMinSpeakScore]。
  final double minSpeakScore;

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
      final reason = _rejectReason(label, c.detection.score, now, force);
      if (reason != null) {
        final s = AppStrings.current;
        _record(
          label,
          c.detection.score,
          '-',
          now,
          '${s.reasonSkipPrefix}$reason',
        );
        continue;
      }
      final text = announceTextFor(label);
      _lastByClass[label.id] = now;
      _lastAny = now;
      final s = AppStrings.current;
      _record(
        label,
        c.detection.score,
        text,
        now,
        force ? s.reasonForced : s.reasonNormal,
      );
      // 记下 future 供调用方/测试等待。不 await 是刻意的：onFrame 由相机
      // 帧回调调用，阻塞它会让掉帧；但必须让「说完了」这件事可被观察。
      _lastSpeech = _speak(text, interrupt: _isP0(label));
      return history.last;
    }
    return null;
  }

  String? _rejectReason(Label label, double score, DateTime now, bool force) {
    // ★ 分数门槛先判，且**不受 force 影响**。
    //
    // 这一点是刻意的：`force` 的语义是「这次不要被冷却挡住」（演示与测试用），
    // 属于**时机**问题；而分数门槛管的是「这个东西到底是不是真的」，
    // 属于**正确性**问题。让 force 绕过它，等于给了一个「逢低分也照念」的后门，
    // 而那正是要防的事。
    final s = AppStrings.current;
    if (score < minSpeakScore) {
      return s.scoreBelowFloor(
        score.toStringAsFixed(2),
        minSpeakScore.toStringAsFixed(2),
      );
    }
    if (force) return null;
    final last = _lastByClass[label.id];
    if (last != null && now.difference(last) < perClassCooldown) {
      return s.perClassCooldown;
    }
    final any = _lastAny;
    if (any != null && now.difference(any) < globalCooldown) {
      return s.globalCooldown;
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
/// 跟随 [AppLocale.current]：中文系统念 `nameZh`，其余念可读英文名。
/// 刻意**不**加修饰语：视障用户最需要的是「是什么 + 在哪」。
String announceTextFor(Label label, [AppLanguage? language]) =>
    labelDisplayName(label, language);
