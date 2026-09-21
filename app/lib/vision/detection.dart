import 'dart:math' as math;
import 'dart:ui' show Rect, Size, Offset;

/// 一个检测结果。坐标是**归一化的 YOLO 格式**（中心点 + 宽高），取值 [0, 1]。
///
/// 用归一化坐标而非像素：它与帧分辨率解耦，因此原生侧不需要知道显示尺寸、
/// Dart 侧也不需要知道模型输入尺寸，两端各自负责自己那一段映射。
class Detection {
  const Detection({
    required this.id,
    required this.score,
    required this.cx,
    required this.cy,
    required this.w,
    required this.h,
  });

  /// 类别 id，对应 `labels.dart` 的 `kLabels` 下标。
  final int id;
  final double score;
  final double cx;
  final double cy;
  final double w;
  final double h;

  /// 由中心点 + 宽高还原成左上角 + 宽高的矩形。
  Rect get normalizedRect => Rect.fromLTWH(cx - w / 2, cy - h / 2, w, h);

  /// 宽或高为 0 的框。归一化后仍可能出现（后处理取整、极细物体），
  /// 画出来是一条不可见的线，必须在绘制前挡掉。
  bool get isDegenerate => w <= 0 || h <= 0 || cx < 0 || cy < 0;

  static Detection? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = _asInt(raw['id']);
    final score = _asDouble(raw['score']);
    final cx = _asDouble(raw['cx']);
    final cy = _asDouble(raw['cy']);
    final w = _asDouble(raw['w']);
    final h = _asDouble(raw['h']);
    if (id == null || score == null || cx == null || cy == null ||
        w == null || h == null) {
      return null;
    }
    if (score.isNaN || cx.isNaN || cy.isNaN || w.isNaN || h.isNaN) return null;
    return Detection(id: id, score: score, cx: cx, cy: cy, w: w, h: h);
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is double && v.isFinite) return v.round();
    return null;
  }

  static double? _asDouble(Object? v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    return null;
  }

  @override
  String toString() =>
      'Detection(id: $id, score: ${score.toStringAsFixed(3)}, '
      'cx: ${cx.toStringAsFixed(3)}, cy: ${cy.toStringAsFixed(3)}, '
      'w: ${w.toStringAsFixed(3)}, h: ${h.toStringAsFixed(3)})';
}

/// 把原始帧的归一化坐标映射到屏幕像素。
///
/// ## 为什么这一层必须单独存在并且有测试
///
/// 相机帧的宽高比几乎永远不等于预览控件的宽高比，中间必然有缩放与留边。
/// 缩放系数、居中偏移、旋转角度三者中任何一个错了，**框都会安静地画偏**：
/// 不抛异常、日志无异常、只是位置不对。所以这里全部做成纯函数，
/// 由 `test/geometry_test.dart` 把边界与旋转都钉死。
///
/// 映射链路：
/// ```
///   归一化帧坐标 --rotateNormalized--> 正立归一化 --scale+offset--> 屏幕像素
/// ```
class DisplayFit {
  const DisplayFit._({
    required this.frame,
    required this.view,
    required this.scale,
    required this.dx,
    required this.dy,
  });

  /// 原始帧尺寸（旋转之前）。
  final Size frame;

  /// 预览控件的尺寸。
  final Size view;

  /// 缩放系数。
  final double scale;

  /// 缩放后的水平/垂直偏移。letterbox 模式下是正的黑边宽度；
  /// cover 模式下是负值（内容被裁到视口外）。
  final double dx;
  final double dy;

  /// 完整放下整帧，多余方向留黑边（= Flutter 的 `BoxFit.contain`）。
  ///
  /// 选它做默认：宁可留黑边也**不能让画面被裁**——被裁掉的那部分若正好是障碍物，
  /// 用户既看不到、也不会有框。
  factory DisplayFit.contain({required Size frame, required Size view}) =>
      DisplayFit._compute(frame: frame, view: view, fit: true);

  /// 铺满视口，超出部分裁剪（= Flutter 的 `BoxFit.cover`）。
  factory DisplayFit.cover({required Size frame, required Size view}) =>
      DisplayFit._compute(frame: frame, view: view, fit: false);

  factory DisplayFit._compute({
    required Size frame,
    required Size view,
    required bool fit,
  }) {
    // 退化输入（帧尺寸为 0、控件尚未布局）不能让 NaN/inf 流进 CustomPainter，
    // 那会直接崩掉绘制。给一个恒等映射。
    if (frame.width <= 0 || frame.height <= 0 ||
        view.width <= 0 || view.height <= 0) {
      return DisplayFit._(
        frame: frame,
        view: view,
        scale: 1,
        dx: 0,
        dy: 0,
      );
    }
    final sx = view.width / frame.width;
    final sy = view.height / frame.height;
    final s = fit ? math.min(sx, sy) : math.max(sx, sy);
    return DisplayFit._(
      frame: frame,
      view: view,
      scale: s,
      dx: (view.width - frame.width * s) / 2,
      dy: (view.height - frame.height * s) / 2,
    );
  }

  /// 归一化帧坐标（已旋转到位）-> 屏幕像素矩形。
  Rect normalizedToScreen(Rect normalized) {
    var r = Rect.fromLTWH(
      dx + normalized.left * frame.width * scale,
      dy + normalized.top * frame.height * scale,
      normalized.width * frame.width * scale,
      normalized.height * frame.height * scale,
    );
    // 模型偶尔会给出越界的框（后处理取整、边界物体）。绘制前夹紧到视口，
    // 否则框会画到预览控件外面去。
    if (view.width > 0 && view.height > 0) {
      final left = r.left.clamp(0.0, view.width);
      final top = r.top.clamp(0.0, view.height);
      final right = r.right.clamp(0.0, view.width);
      final bottom = r.bottom.clamp(0.0, view.height);
      r = Rect.fromLTRB(left, top, math.max(left, right), math.max(top, bottom));
    }
    return r;
  }

  @override
  String toString() => 'DisplayFit(frame: $frame, view: $view, '
      'scale: ${scale.toStringAsFixed(4)}, dx: ${dx.toStringAsFixed(1)}, '
      'dy: ${dy.toStringAsFixed(1)})';
}

/// 把归一化矩形按顺时针 [quarterTurns] 个 90° 旋转。
///
/// 旋转在**归一化空间**做，公式直接用坐标变换推导：
/// - 0 个：`(x, y) -> (x, y)`，宽高不变
/// - 1 个：`(x, y) -> (1-y, x)`，宽高互换
/// - 2 个：`(x, y) -> (1-x, 1-y)`，宽高不变
/// - 3 个：`(x, y) -> (y, 1-x)`，宽高互换
///
/// 推导基于「整个帧绕中心旋转」，因此旋转后仍然是一个轴对齐矩形，
/// 只是落在新坐标系里的位置变了。
Rect rotateNormalized(Rect r, {required int quarterTurns}) {
  final q = quarterTurns % 4;
  final w = r.width;
  final h = r.height;
  if (q == 0) return r;
  if (q == 1) return Rect.fromLTWH(1 - r.top - h, r.left, h, w);
  if (q == 2) return Rect.fromLTWH(1 - r.left - w, 1 - r.top - h, w, h);
  return Rect.fromLTWH(r.top, 1 - r.left - w, h, w);
}

/// 由角度（0/90/180/270）得到 quarter turns。非法角度按 0 处理。
int quarterTurnsFromDegrees(int degrees) {
  final d = ((degrees % 360) + 360) % 360;
  if (d % 90 != 0) return 0;
  return d ~/ 90;
}

/// 绘制用的居中偏移，供需要手动摆放叠加层时使用。
Offset displayOffset(DisplayFit fit) => Offset(fit.dx, fit.dy);

/// 把一帧的检测框从「归一化原始帧坐标」一路映射到屏幕像素。
///
/// 这是唯一的映射入口：把旋转、letterbox 缩放、居中偏移串在一起，
/// 避免各处自己算一遍而其中一处漏了旋转。
///
/// [fit] 必须用**旋转后**的帧尺寸构造（见 [rotatedFrameSize]）。
List<({Detection detection, Rect rect})> mapDetectionsToScreen({
  required List<Detection> detections,
  required int rotationDegrees,
  required DisplayFit fit,
}) {
  final q = quarterTurnsFromDegrees(rotationDegrees);
  return [
    for (final d in detections)
      (
        detection: d,
        rect: fit.normalizedToScreen(
          rotateNormalized(d.normalizedRect, quarterTurns: q),
        ),
      ),
  ];
}

/// 原始帧尺寸 + 旋转角 -> 旋转后的帧尺寸（90/270 度时宽高互换）。
///
/// [DisplayFit] 必须用这个尺寸构造：归一化坐标在旋转之后才与屏幕方向一致，
/// 用错尺寸的表现是框横向被拉伸或压缩，不报错。
Size rotatedFrameSize(Size frame, int rotationDegrees) {
  final q = quarterTurnsFromDegrees(rotationDegrees);
  return q.isOdd ? Size(frame.height, frame.width) : frame;
}
