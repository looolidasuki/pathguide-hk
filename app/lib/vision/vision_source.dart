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

/// 原生侧的诊断快照。
///
/// 为什么要有这个：相机链路里「预览正常但没有检测结果」可以由至少五种原因造成
/// （相机没启动、分析器没跑、取平面失败、推理抛异常、阈值过高），
/// 而它们在界面上看起来完全一样。没有计数就只能靠反复重新构建去猜。
///
/// 每个字段都对应一个具体的失败点，界面上直接显示，用户不必读 logcat。
class VisionDiagnostics {
  const VisionDiagnostics({
    required this.modelReady,
    required this.modelPath,
    required this.inputSize,
    required this.modelClassCount,
    required this.analyzedFrames,
    required this.analyzeErrors,
    required this.skippedReason,
    required this.analyzeError,
    required this.frameWidth,
    required this.frameHeight,
    required this.frameFormat,
    required this.frameMaxScore,
    required this.frameMinScore,
    required this.detectionCount,
    required this.invalidDetections,
    required this.invalidSample,
    required this.anchors,
    required this.channels,
    required this.transposed,
  });

  final bool modelReady;
  final String? modelPath;
  final int inputSize;
  final int modelClassCount;

  /// 分析器收到的帧数。**为 0 就说明相机分析回路根本没跑起来。**
  final int analyzedFrames;
  final int analyzeErrors;

  /// 最近一帧被跳过的原因。空串表示正常处理。
  final String skippedReason;

  /// 最近一次分析异常的类型与消息。空串表示没发生异常。
  ///
  /// 与 [skippedReason] 分开是刻意的：混用会让错误信息被下一帧覆盖，
  /// 真机上就是这样把线索丢掉的。
  final String analyzeError;

  final int frameWidth;
  final int frameHeight;

  /// 最近一帧的格式描述（平面数、旋转角、UV 步长），用于核对取帧假设。
  final String frameFormat;

  /// 最近一帧的最高置信度，**不受阈值影响**。
  ///
  /// 这是区分「模型没给高分」与「阈值卡太严」的关键：
  /// 若它明显高于阈值却仍无框，问题在过滤或映射；若它本身极低，问题在模型或输入。
  final double frameMaxScore;

  /// 最近一帧的最低置信度。与 [frameMaxScore] 一起看范围是否正常。
  ///
  /// 模型最后一层是 sigmoid，分数必在 [0,1]。若 max > 1，
  /// 说明**解码读错了通道或步长**——这是硬性判据，不需要猜。
  final double frameMinScore;

  /// 最近一帧的检测数（阈值与无效值过滤后）。
  final int detectionCount;

  /// 被判定为无效而丢弃的检测累计数。
  final int invalidDetections;

  /// 最近一个无效检测的原始数值，用于定位读错通道。
  final String invalidSample;

  /// 模型张量布局，用于核对解码假设。
  final int anchors;
  final int channels;
  final bool transposed;

  @override
  String toString() => 'analyzed=$analyzedFrames errors=$analyzeErrors '
      'skip="$skippedReason" frame=${frameWidth}x$frameHeight '
      'maxScore=${frameMaxScore.toStringAsFixed(3)}';
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
