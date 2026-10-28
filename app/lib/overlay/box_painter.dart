import 'package:flutter/material.dart';

import '../vision/detection.dart';
import '../vision/labels.dart';

/// 检测框叠加层的调色板。
///
/// 按类别**分组**着色而不是一类一色：几十类各给一个颜色时，相邻色相
/// 在阳光下的手机屏上根本分不出。按组着色让「这是障碍物还是引导设施」
/// 一眼可辨，组内再靠标签文字区分。
abstract final class BoxPalette {
  static const Map<String, Color> _byGroup = <String, Color>{
    'footbridge': Color(0xFF34D399), // 綠：可前往的設施
    'obstacle': Color(0xFFFF5C7A), // 紅：需要避開的障礙物
    'guide': Color(0xFF38BDF8), // 藍：盲道、斑馬線等引導設施
    'indoor': Color(0xFFC084FC), // 紫：室內設施
    'classifier': Color(0xFFFFA94D), // 橙：店鋪門面
    'train_only': Color(0xFF94A3B8), // 灰：訓練期佔位類
  };

  /// 未在分组表里的类别用的兜底色。
  static const Color fallback = Color(0xFF38BDF8);

  static Color of(String group) => _byGroup[group] ?? fallback;
}

/// 把检测框画到预览之上。
///
/// 入参 [mapped] 必须已经是**屏幕坐标**（由 [mapDetectionsToScreen] 得到）。
/// 这个类刻意不做任何坐标计算——坐标错位的 bug 只允许存在于一处。
///
/// **名字里带 `Detection` 前缀是必需的**：Flutter 的 `material.dart` 自己导出了
/// 一个 `BoxPainter`（在 `decoration.dart`）。同名会导致 `CustomPaint(painter: ...)`
/// 解析到 Flutter 那个，编译报 `invocation_of_non_function` + `ambiguous_import`。
class DetectionBoxPainter extends CustomPainter {
  DetectionBoxPainter({
    required this.mapped,
    required this.showLabels,
    this.fontFamily,
    this.textScaler = TextScaler.noScaling,
    this.englishLabels = false,
  });

  final List<({Detection detection, Rect rect})> mapped;
  final bool showLabels;
  final String? fontFamily;
  final TextScaler textScaler;
  final bool englishLabels;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final item in mapped) {
      final label = labelOf(item.detection.id);
      final color = label == null
          ? BoxPalette.fallback
          : BoxPalette.of(label.group);

      final rect = item.rect;
      if (rect.width < 2 || rect.height < 2) continue; // 太小的框画出来是噪点

      // 半透明填充：实心会挡住物体本身，全透明又看不出框的边界。
      canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.12));
      canvas.drawRect(
        rect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );

      // 角标：在框的左上角画粗短线，比整框描边更容易在余光里看到。
      _cornerMarks(canvas, rect, color);

      if (showLabels) _label(canvas, size, rect, label, item.detection.score);
    }
    canvas.restore();
  }

  void _cornerMarks(Canvas canvas, Rect rect, Color color) {
    const len = 14.0;
    final p = Paint()
      ..color = color
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(len, 0), p);
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(0, len), p);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(-len, 0), p);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(0, len), p);
  }

  void _label(Canvas canvas, Size size, Rect rect, Label? label, double score) {
    final text = label == null
        ? 'id? ${score.toStringAsFixed(2)}'
        : '${englishLabels ? label.nameEn.replaceAll('_', ' ') : label.nameZh} ${score.toStringAsFixed(2)}';
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFamily,
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w700,
          // 深色描边提高在杂乱背景上的可读性
          shadows: <Shadow>[Shadow(blurRadius: 3, color: Colors.black87)],
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout(maxWidth: size.width > 10 ? size.width - 10 : 0);

    // 标签贴在框上方；框贴顶时改放在框内，避免跑出屏幕。
    var dx = rect.left;
    var dy = rect.top - tp.height - 4;
    if (dy < 0) dy = rect.top + 2;
    if (dx + tp.width > rect.left + rect.width && rect.width > tp.width) {
      dx = rect.right - tp.width;
    }
    dx = dx.clamp(
      0.0,
      size.width > tp.width + 10 ? size.width - tp.width - 10 : 0.0,
    );
    dy = dy.clamp(
      0.0,
      size.height > tp.height + 4 ? size.height - tp.height - 4 : 0.0,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(dx, dy, tp.width + 10, tp.height + 4),
        const Radius.circular(4),
      ),
      Paint()..color = const Color(0xE6000000),
    );
    tp.paint(canvas, Offset(dx + 5, dy + 2));
  }

  @override
  bool shouldRepaint(covariant DetectionBoxPainter old) =>
      old.mapped != mapped ||
      old.showLabels != showLabels ||
      old.englishLabels != englishLabels ||
      old.fontFamily != fontFamily ||
      old.textScaler != textScaler;
}
