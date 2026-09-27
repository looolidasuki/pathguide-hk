import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
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
    test('frameSize 与 rotationDegrees 都在接口上', () {
      // rotationDegrees 曾在 UI 里被硬编码为 90（`_rotationDegrees`），
      // 而 iOS 的 AVFoundation 会给出不同角度——几何常量不能写在 UI 里。
      final VisionSource s = MockVisionSource(
        frameSize: const Size(1280, 720),
      );
      expect(s.frameSize, const Size(1280, 720));
      expect(s.rotationDegrees, isA<int>());
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
