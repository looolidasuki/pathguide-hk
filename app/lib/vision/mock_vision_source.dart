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
/// 等真模型一到位只换一个实现类。
///
/// 它同时是**画框正确性的验证工具**：因为框的位置是算出来的而不是猜的，
/// 可以故意让框按已知规律移动（例如从左到右扫过、再贴边），
/// 在屏幕上就能一眼看出映射是否偏移。
class MockVisionSource implements VisionSource {
  MockVisionSource({
    this.frameSize = const Size(1280, 720),
    this.interval = const Duration(milliseconds: 120),
    this.threshold = 0.3,
    List<int>? classIds,
  }) : classIds = classIds ?? const <int>[7];

  /// 模拟的原始帧尺寸（旋转之前）。默认用横屏 1280x720，
  /// 与 Android 后置相机在竖屏下的真实输出一致。
  @override
  final Size frameSize;

  /// 模拟的推理间隔。
  final Duration interval;

  @override
  double threshold;

  @override
  bool mirrored = false;

  /// 要模拟的类别 id。默认只出 `bin`（id=7），
  /// 因为它是当前唯一有足够训练数据的类。
  final List<int> classIds;

  final StreamController<VisionFrame> _controller =
      StreamController<VisionFrame>.broadcast();
  Timer? _timer;
  int _tick = 0;

  @override
  Stream<VisionFrame> get frames => _controller.stream;

  @override
  Future<void> initialize() async {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _emit());
  }

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
      detections: detections.where((d) => d.score >= threshold).toList(),
      inferenceMs: 18 + 6 * math.sin(t * 0.7),
      frameWidth: frameSize.width.round(),
      frameHeight: frameSize.height.round(),
      queueDepth: 0,
    ));
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _controller.close();
  }
}
