import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/vision/detection.dart';
import 'package:pathguide/vision/mock_vision_source.dart';
import 'package:pathguide/vision/platform_vision.dart';
import 'package:pathguide/vision/vision_source.dart';

/// `VisionSource` 契约测试。
///
/// ## 为什么这个文件必须存在
///
/// 项目曾声明「`lib/` 下除接口实现之外的代码只依赖 [VisionSource]」，
/// 但那是**假的**：`PlatformVision` 从未实现该接口，UI 通篇用
/// `_platform.xxx` 与 `_mock?.xxx` 两套并行分支。
/// 结果是换平台要实现两遍（一遍原生、一遍抄 UI 分支），
/// 且没有任何机制保证两个实现行为一致。
///
/// 本文件把「谁必须实现接口」和「接口必须提供什么」变成可执行的断言。
void main() {
  group('实现关系', () {
    test('MockVisionSource 实现 VisionSource', () {
      final VisionSource s = MockVisionSource();
      expect(s, isA<VisionSource>());
    });

    test('PlatformVision 也实现 VisionSource', () {
      // 这是本轮重构的核心目标：平台实现必须与假实现走同一个接口，
      // 否则 UI 无法只依赖抽象。
      final VisionSource s = PlatformVision();
      expect(s, isA<VisionSource>());
    });

    test('两者可互换赋值给同一接口类型', () {
      // 覆盖「UI 只持有一个 VisionSource」这一用法。
      final List<VisionSource> sources = <VisionSource>[
        MockVisionSource(),
        PlatformVision(),
      ];
      for (final s in sources) {
        expect(s.threshold, inInclusiveRange(0.0, 1.0));
      }
    });
  });

  group('接口必须提供的东西', () {
    test('frameSize 是**旋转之后**的尺寸：0 度不换轴', () {
      final VisionSource s = MockVisionSource(
        frameSize: const Size(1280, 720),
        rotationDegrees: 0,
      );
      expect(s.frameSize, const Size(1280, 720));
    });

    test('frameSize 是**旋转之后**的尺寸：90 度换轴', () {
      // 这一条是本轮重构的核心语义：frameSize 承诺已旋转到位，
      // 因此 UI 不再自行 rotatedFrameSize，几何量的唯一来源是来源本身。
      // 首次写这个测试时把它当成了「原始尺寸」，断言写反了——
      // 实现是对的（1280x720 顺时针转 90 度就是 720x1280）。
      final VisionSource s = MockVisionSource(
        frameSize: const Size(1280, 720),
        rotationDegrees: 90,
      );
      expect(s.frameSize, const Size(720, 1280));
    });

    test('frameSize 是**旋转之后**的尺寸：180 度不换轴', () {
      final VisionSource s = MockVisionSource(
        frameSize: const Size(1280, 720),
        rotationDegrees: 180,
      );
      expect(s.frameSize, const Size(1280, 720));
    });

    test('frameSize 是**旋转之后**的尺寸：270 度换轴', () {
      final VisionSource s = MockVisionSource(
        frameSize: const Size(1280, 720),
        rotationDegrees: 270,
      );
      expect(s.frameSize, const Size(720, 1280));
    });

    test('rotationDegrees 在接口上，且非法角度归零', () {
      expect(MockVisionSource(rotationDegrees: 90).rotationDegrees, 90);
      expect(MockVisionSource(rotationDegrees: 45).rotationDegrees, 0);
      expect(MockVisionSource(rotationDegrees: -90).rotationDegrees, 270);
      expect(MockVisionSource(rotationDegrees: 450).rotationDegrees, 90);
    });

    test('rotationDegrees 是 90 的整数倍且归一化到 [0,360)', () {
      final s = MockVisionSource();
      expect(s.rotationDegrees % 90, 0);
      expect(s.rotationDegrees, inInclusiveRange(0, 359));
    });

    test('threshold 可读可写且被夹在 [0,1]', () {
      final s = MockVisionSource();
      s.threshold = 0.42;
      expect(s.threshold, closeTo(0.42, 1e-9));
      s.threshold = 1.7;
      expect(s.threshold, lessThanOrEqualTo(1.0));
      s.threshold = -0.3;
      expect(s.threshold, greaterThanOrEqualTo(0.0));
    });

    test('diagnostics 在接口上，且不支持的实现返回 null 而不是抛异常', () {
      // 假数据源没有原生诊断，它必须返回 null；UI 据此隐藏诊断面板，
      // 而不是在切到假数据时仍去轮询一个不存在的原生设备（当前就是这样）。
      expect(MockVisionSource().diagnostics(), completion(isNull));
    });

    test('显示名用于界面提示', () {
      expect(MockVisionSource().displayName, isNotEmpty);
      expect(PlatformVision().displayName, isNotEmpty);
    });
  });

  group('坐标契约', () {
    test('来源已把画面转正，映射时不得再旋转一次', () {
      // 竖屏后置相机：原始帧 1280x720，顺时针 90 度才正立 -> frameSize 720x1280。
      final VisionSource s = MockVisionSource(
        frameSize: const Size(1280, 720),
        rotationDegrees: 90,
      );
      expect(s.frameSize, const Size(720, 1280));

      // 取一个**偏离中心**的框：再转 90 度的话，(0.25, 0.5) 会跑到 (0.5, 0.25)，
      // 屏幕上相差半幅画面。这个测试就是用来钉住「转正只做一次」的。
      const Detection d = Detection(
        id: 7,
        score: 0.9,
        cx: 0.25,
        cy: 0.5,
        w: 0.2,
        h: 0.2,
      );
      final DisplayFit fit = DisplayFit.contain(
        frame: s.frameSize,
        view: const Size(720, 1280), // 与帧同比 -> scale=1、无偏移
      );
      final mapped = mapDetectionsToScreen(
        detections: const <Detection>[d],
        fit: fit,
      );
      expect(mapped, hasLength(1));
      final Rect r = mapped.single.rect;

      // scale=1 且无偏移，屏幕坐标就等于归一化坐标乘以帧尺寸。
      expect(r.center.dx, closeTo(0.25 * 720, 1e-6));
      expect(r.center.dy, closeTo(0.5 * 1280, 1e-6));
      // 反证：重复旋转会得到 (0.5, 0.25)。
      expect(r.center.dx, isNot(closeTo(0.5 * 720, 1e-6)));
      expect(r.center.dy, isNot(closeTo(0.25 * 1280, 1e-6)));
    });
  });

  group('生命周期', () {
    test('initialize 返回可展示的结果，而不是抛异常', () {
      // 模型缺失、相机不可用都应当在界面上显示原因，
      // 而不是让 initialize 抛异常把界面打崩。
      final s = MockVisionSource();
      expect(s.initialize(), completion(isA<VisionSourceStatus>()));
    });

    test('阈值越界后仍能正常出帧', () async {
      final s = MockVisionSource(interval: const Duration(milliseconds: 10));
      s.threshold = 0.99;
      final status = await s.initialize();
      expect(status.ok, isTrue);
      final first = await s.frames.first.timeout(const Duration(seconds: 2));
      for (final d in first.detections) {
        expect(d.score, greaterThanOrEqualTo(s.threshold));
      }
      await s.dispose();
    });

    test('dispose 后流关闭', () async {
      final s = MockVisionSource(interval: const Duration(milliseconds: 10));
      await s.initialize();
      await s.dispose();
      await expectLater(s.frames, emitsDone);
    });
  });
}
