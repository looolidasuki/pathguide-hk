import 'dart:ui' show Size;

import 'detection.dart';

/// 一帧的推理结果连同性能数据。
class VisionFrame {
  const VisionFrame({
    required this.detections,
    required this.inferenceMs,
    required this.frameWidth,
    required this.frameHeight,
    required this.queueDepth,
  });

  final List<Detection> detections;

  /// 原生侧单帧推理耗时（毫秒）。**不含**取帧与格式转换。
  final double inferenceMs;

  /// 这一帧的原始尺寸（旋转之前）。
  final int frameWidth;
  final int frameHeight;

  /// 当前排队等待推理的帧数。持续 > 1 说明推理跟不上相机帧率，
  /// 必须丢弃旧帧而不是排队——排队会让画面延迟越积越大。
  final int queueDepth;

  int get frameArea => frameWidth * frameHeight;
}

/// 检测结果来源的抽象接口。
///
/// `lib/` 下除本文件与 `platform_vision_source.dart` 之外的代码
/// **只依赖这个接口**，不依赖相机、不依赖平台通道。因此：
/// - UI、画框、播报、防抖逻辑可以用 [VisionSource] 的假实现单独开发和测试；
/// - Android 与 iOS 各自实现一次原生层，Dart 侧零改动。
///
/// 这层抽象是「MacBook 上补 iOS」的前提，见
/// `docs/superpowers/plans/2026-09-22-flutter-android-env.md` §6。
abstract class VisionSource {
  /// 归一化坐标系下的帧尺寸（= 旋转到位之后的帧尺寸）。
  ///
  /// 画框必须用它，**不能用预览控件的尺寸**：前者决定坐标含义，后者只决定显示。
  Size get frameSize;

  /// 检测结果流。实现方负责抽帧，不必每帧都推理。
  Stream<VisionFrame> get frames;

  /// 初始化。抛异常表示模型缺失或相机不可用，调用方须展示明确提示。
  Future<void> initialize();

  /// 置信度门槛，[0, 1]。
  set threshold(double value);
  double get threshold;

  /// 推理时是否把输入水平镜像（前置相机需要）。
  set mirrored(bool value);

  Future<void> dispose();
}
