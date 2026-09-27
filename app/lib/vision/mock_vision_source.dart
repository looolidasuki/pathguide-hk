import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'detection.dart';
import 'vision_source.dart';

/// 不接相机、不接模型的假检测源。
///
/// ## 它的用途不是「凑数」
///
/// 读屏用户的这条产品线里，**总有人要先在没有硬件的情况下把界面做出来**：
/// 模型还没导出、真机不在手上、或者只是要调叠加层的画法。
/// 有了这个假源，UI、画框、播报防抖、性能面板全都能独立开发和测试，
/// 等真模型一到位只换一个实现类——**这正是 [VisionSource] 抽象存在的理由**。
///
/// 它同时是**画框正确性的验证工具**：框的位置是算出来的而不是猜的，
/// 可以故意让框按已知规律移动（水平往返、对角扫描、贴角摆动），
/// 在屏幕上就能一眼看出映射是否偏移。
class MockVisionSource implements VisionSource {
  MockVisionSource({
    Size frameSize = const Size(1280, 720),
    this.interval = const Duration(milliseconds: 120),
    double threshold = 0.30,
    int rotationDegrees = 90,
    List<int>? classIds,
  })  : _rawFrameSize = frameSize,
        _rotationDegrees = _normalizeRotation(rotationDegrees),
        _threshold = threshold.clamp(0.0, 1.0),
        classIds = classIds ?? const <int>[7];

  /// 模拟的**原始**帧尺寸（旋转之前）。默认用横屏 1280x720，
  /// 与 Android 后置相机在竖屏下的真实输出一致。
  final Size _rawFrameSize;

  final int _rotationDegrees;

  /// 模拟的推理间隔。
  final Duration interval;

  double _threshold;

  /// 要模拟的类别 id。默认只出 `bin`（id=7），
  /// 因为它是当前唯一有足够训练数据的类。
  final List<int> classIds;

  final StreamController<VisionFrame> _controller =
      StreamController<VisionFrame>.broadcast();
  Timer? _timer;
  int _tick = 0;

  static int _normalizeRotation(int deg) {
    final d = ((deg % 360) + 360) % 360;
    return d % 90 == 0 ? d : 0;
  }

  @override
  String get displayName => '假数据';

  /// 与 [PlatformVision] 同一语义：**旋转之后**的帧尺寸。
  ///
  /// 90/270 度时宽高互换——这正是画框前必须做 `rotateNormalized` 的原因。
  @override
  Size get frameSize => _rotationDegrees % 180 == 90
      ? Size(_rawFrameSize.height, _rawFrameSize.width)
      : _rawFrameSize;

  @override
  int get rotationDegrees => _rotationDegrees;

  @override
  double get threshold => _threshold;

  /// 写入即夹紧到 [0,1]。越界值曾导致「滑动条拉到顶就一个框都不出」，
  /// 而界面上看不出原因。
  @override
  set threshold(double value) => _threshold = value.clamp(0.0, 1.0);

  @override
  Stream<VisionFrame> get frames => _controller.stream;

  @override
  Future<VisionSourceStatus> initialize() async {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _emit());
    return const VisionSourceStatus(
      ok: true,
      message: '假数据模式：三个按已知规律运动的框，用于校验坐标映射',
    );
  }

  /// 假数据源没有原生侧，因此没有诊断信息。
  ///
  /// 返回 `null` 而不是抛异常：UI 据此隐藏诊断面板，
  /// 而不是在切到假数据后仍去轮询一个不存在的原生设备。
  @override
  Future<VisionDiagnostics?> diagnostics() async => null;

  void _emit() {
    if (_controller.isClosed) return;
    _tick++;
    final t = _tick / 60.0;

    // 三个按已知规律运动的框，用来肉眼校验坐标映射：
    //   1) 水平往返扫描，垂直位置固定在 0.35
    //   2) 从左上角扫到右下角，检验两轴同时变化
    //   3) 贴着一个角做小幅度摆动，检验边界夹紧
    final sweep = (math.sin(t) + 1) / 2; // [0,1]
    final detections = <Detection>[
      for (var i = 0; i < classIds.length; i++)
        Detection(
          id: classIds[i],
          score: 0.55 + 0.35 * ((math.sin(t * (i + 1)) + 1) / 2),
          cx: i == 0
              ? 0.1 + 0.8 * sweep
              : i == 1
                  ? 0.15 + 0.7 * sweep
                  : 0.05 + 0.03 * sweep,
          cy: i == 0
              ? 0.35
              : i == 1
                  ? 0.15 + 0.7 * sweep
                  : 0.05 + 0.03 * sweep,
          w: 0.08 + 0.04 * i,
          h: 0.16 + 0.06 * i,
        ),
    ];

    _controller.add(VisionFrame(
      detections: detections.where((d) => d.score >= _threshold).toList(),
      inferenceMs: 18 + 6 * math.sin(t * 0.7),
      frameWidth: _rawFrameSize.width.round(),
      frameHeight: _rawFrameSize.height.round(),
    ));
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _controller.close();
  }
}
