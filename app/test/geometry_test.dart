import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/vision/detection.dart';

/// 坐标映射：相机帧（归一化）→ 屏幕像素。
///
/// 这里是整个 Demo 里最容易静默出错的地方：缩放、居中偏移、旋转，任何一处错了
/// 都不会抛异常，只是框安静地画偏。所以边界与旋转都显式断言。
void main() {
  group('DisplayFit.contain', () {
    test('同宽高比时只做缩放、无偏移', () {
      final fit = DisplayFit.contain(
        frame: const Size(1280, 720),
        view: const Size(1280, 720),
      );
      expect(fit.scale, 1.0);
      expect(fit.dx, 0.0);
      expect(fit.dy, 0.0);
      final r = fit.normalizedToScreen(const Rect.fromLTWH(0, 0, 0.5, 0.5));
      expect(r.left, 0.0);
      expect(r.top, 0.0);
      expect(r.width, 640.0);
      expect(r.height, 360.0);
    });

    test('帧更宽时上下留黑边（letterbox）', () {
      // 1280x720 的帧放进 1280x1280 的方屏：scale=1，垂直居中
      final fit = DisplayFit.contain(
        frame: const Size(1280, 720),
        view: const Size(1280, 1280),
      );
      expect(fit.scale, 1.0);
      expect(fit.dx, 0.0);
      expect(fit.dy, 280.0);
      final full = fit.normalizedToScreen(const Rect.fromLTWH(0, 0, 1, 1));
      expect(full.top, 280.0);
      expect(full.height, 720.0);
    });

    test('帧更高时左右留黑边', () {
      // 720x1280 的帧放进 1280x720 的横屏：scale = 720/1280 = 0.5625
      final fit = DisplayFit.contain(
        frame: const Size(720, 1280),
        view: const Size(1280, 720),
      );
      expect(fit.scale, closeTo(720 / 1280, 1e-9));
      expect(fit.dy, 0.0);
      expect(fit.dx, closeTo((1280 - 720 * (720 / 1280)) / 2, 1e-9));
    });

    test('返回值不会超出显示区域', () {
      // 帧上有越界的归一化框（模型/后处理出错时会出现），绘制前必须夹紧
      final fit = DisplayFit.contain(
        frame: const Size(1280, 720),
        view: const Size(400, 800),
      );
      final r = fit.normalizedToScreen(const Rect.fromLTWH(-0.2, -0.1, 1.5, 1.2));
      expect(r.left, greaterThanOrEqualTo(0.0));
      expect(r.top, greaterThanOrEqualTo(0.0));
      expect(r.right, lessThanOrEqualTo(400.0));
      expect(r.bottom, lessThanOrEqualTo(800.0));
    });

    test('中心的框映射到显示区域中心', () {
      final fit = DisplayFit.contain(
        frame: const Size(640, 480),
        view: const Size(1080, 1920),
      );
      final r = fit.normalizedToScreen(const Rect.fromLTWH(0.45, 0.45, 0.1, 0.1));
      // 归一化中心 (0.5, 0.5) 必须落在显示区域中心；宽高不退化
      expect(r.width, greaterThan(0));
      expect(r.height, greaterThan(0));
      expect(r.center.dx, closeTo(1080 / 2, 1e-6));
      expect(r.center.dy, closeTo(1920 / 2, 1e-6));
    });

    test('退化输入返回空矩形而不是 NaN', () {
      // 帧尺寸为 0 时不能产生 NaN/inf，那会让 CustomPainter 直接崩
      final fit = DisplayFit.contain(
        frame: const Size(0, 0),
        view: const Size(400, 800),
      );
      final r = fit.normalizedToScreen(const Rect.fromLTWH(0.1, 0.1, 0.2, 0.2));
      expect(r.left.isFinite, isTrue);
      expect(r.top.isFinite, isTrue);
      expect(r.width.isFinite, isTrue);
      expect(r.height.isFinite, isTrue);
    });
  });

  group('DisplayFit.cover', () {
    test('铺满时不留黑边、内容被裁切', () {
      // 1280x720 铺满 400x800：scale = 800/720 = 1.111，横向被裁
      final fit = DisplayFit.cover(
        frame: const Size(1280, 720),
        view: const Size(400, 800),
      );
      expect(fit.scale, closeTo(800 / 720, 1e-9));
      expect(fit.dy, 0.0);
      expect(fit.dx, lessThan(0.0)); // 负偏移 = 两侧内容在视口外
      final full = fit.normalizedToScreen(const Rect.fromLTWH(0, 0, 1, 1));
      expect(full.width, greaterThanOrEqualTo(400.0));
      expect(full.width, closeTo(1280 * (800 / 720), 1e-6));
    });
  });

  group('坐标旋转', () {
    test('0 度不改变归一化坐标', () {
      final r = rotateNormalized(
        const Rect.fromLTWH(0.25, 0.5, 0.5, 0.25),
        quarterTurns: 0,
      );
      expect(r, const Rect.fromLTWH(0.25, 0.5, 0.5, 0.25));
    });

    test('90 度交换宽高并把 (x,y) 映射到 (1-y, x)', () {
      final r = rotateNormalized(
        const Rect.fromLTWH(0.1, 0.2, 0.3, 0.4),
        quarterTurns: 1,
      );
      // 左上角 (0.1,0.2) -> (1-0.2, 0.1) = (0.8, 0.1)
      expect(r.left, closeTo(0.8, 1e-9));
      expect(r.top, closeTo(0.1, 1e-9));
      // 宽高互换
      expect(r.width, closeTo(0.4, 1e-9));
      expect(r.height, closeTo(0.3, 1e-9));
    });

    test('180 度关于中心镜像', () {
      final r = rotateNormalized(
        const Rect.fromLTWH(0.1, 0.2, 0.3, 0.4),
        quarterTurns: 2,
      );
      expect(r.left, closeTo(0.6, 1e-9));
      expect(r.top, closeTo(0.4, 1e-9));
      expect(r.width, closeTo(0.3, 1e-9));
      expect(r.height, closeTo(0.4, 1e-9));
    });

    test('270 度等价于反向 90 度', () {
      final once = rotateNormalized(
        const Rect.fromLTWH(0.1, 0.2, 0.3, 0.4),
        quarterTurns: 3,
      );
      final thrice = rotateNormalized(
        rotateNormalized(
          rotateNormalized(const Rect.fromLTWH(0.1, 0.2, 0.3, 0.4), quarterTurns: 1),
          quarterTurns: 1,
        ),
        quarterTurns: 1,
      );
      expect(once.left, closeTo(thrice.left, 1e-9));
      expect(once.top, closeTo(thrice.top, 1e-9));
      expect(once.width, closeTo(thrice.width, 1e-9));
      expect(once.height, closeTo(thrice.height, 1e-9));
    });

    test('旋转四次回到原点', () {
      const original = Rect.fromLTWH(0.1, 0.2, 0.3, 0.4);
      var r = original;
      for (var i = 0; i < 4; i++) {
        r = rotateNormalized(r, quarterTurns: 1);
      }
      expect(r.left, closeTo(original.left, 1e-9));
      expect(r.top, closeTo(original.top, 1e-9));
      expect(r.width, closeTo(original.width, 1e-9));
      expect(r.height, closeTo(original.height, 1e-9));
    });

    test('旋转后的框仍然落在 [0,1] 内', () {
      for (var q = 0; q < 4; q++) {
        final r = rotateNormalized(
          const Rect.fromLTWH(0.05, 0.05, 0.9, 0.9),
          quarterTurns: q,
        );
        expect(r.left, greaterThanOrEqualTo(-1e-9), reason: 'q=$q');
        expect(r.top, greaterThanOrEqualTo(-1e-9), reason: 'q=$q');
        expect(r.right, lessThanOrEqualTo(1 + 1e-9), reason: 'q=$q');
        expect(r.bottom, lessThanOrEqualTo(1 + 1e-9), reason: 'q=$q');
      }
    });
  });

  group('Detection', () {
    test('normalizedRect 由中心点与宽高还原', () {
      const d = Detection(id: 7, score: 0.9, cx: 0.5, cy: 0.5, w: 0.2, h: 0.4);
      expect(d.normalizedRect, const Rect.fromLTWH(0.4, 0.3, 0.2, 0.4));
    });

    test('面积为零的框被判定为退化', () {
      const d = Detection(id: 7, score: 0.9, cx: 0.5, cy: 0.5, w: 0.0, h: 0.4);
      expect(d.isDegenerate, isTrue);
    });

    test('正常框不是退化框', () {
      const d = Detection(id: 7, score: 0.9, cx: 0.5, cy: 0.5, w: 0.2, h: 0.4);
      expect(d.isDegenerate, isFalse);
    });
  });
}
