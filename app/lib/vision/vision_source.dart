import 'dart:ui' show Size;

import 'detection.dart';

/// 一帧的推理结果连同性能数据。
class VisionFrame {
  const VisionFrame({
    required this.detections,
    required this.inferenceMs,
    required this.frameWidth,
    required this.frameHeight,
  });

  final List<Detection> detections;

  /// 单帧推理耗时（毫秒）。**不含**取帧与格式转换。
  final double inferenceMs;

  /// 这一帧的**原始**尺寸（旋转之前）。
  ///
  /// 保留它是给诊断用的：`frameSize` 是旋转后的尺寸，两者不一致往往是
  /// 「框整体偏移」的第一嫌疑。
  final int frameWidth;
  final int frameHeight;
}

/// 一次初始化尝试的结果。
///
/// 为什么用返回值而不是抛异常：模型缺失、相机被占用、权限被拒都要在界面上
/// 显示**可操作的原因**，而不是把界面打崩。抛异常的实现最终还是要被
/// 调用方 catch 后转成文案，不如在类型上就写清楚。
class VisionSourceStatus {
  const VisionSourceStatus({required this.ok, required this.message, this.error});

  final bool ok;

  /// 面向用户的说明（成功也要有，例如「模型已加载，N 类」——N 由模型清单决定，
/// 不要写死，类别表会随版本增长）。
  final String message;

  /// 失败细节，供诊断面板显示。成功时为 null。
  final String? error;

  @override
  String toString() => 'VisionSourceStatus(ok=$ok, message=$message, error=$error)';
}

/// 检测结果来源的抽象接口。
///
/// ## 这层抽象到底约束了什么（曾经是假的）
///
/// 本文件原先写着「`lib/` 下除实现之外的代码只依赖 [VisionSource]」，
/// 但 `PlatformVision` **从未实现**该接口，UI 里通篇是
/// `_platform.xxx` 与 `_mock?.xxx` 两套并行分支。后果：
/// - 换平台要做两遍（一遍原生、一遍抄 UI 分支）；
/// - 没有任何机制保证两个实现行为一致；
/// - 平台特有的几何量（旋转角）被硬编码进 UI。
///
/// 现在**两个实现都必须 implements [VisionSource]**，由
/// `test/vision_source_contract_test.dart` 断言，UI 只持有一个该类型的引用。
abstract class VisionSource {
  /// 显示名，用于界面提示当前用的是哪个来源。
  String get displayName;

  /// 归一化坐标系下的帧尺寸（= **旋转到位之后**的帧尺寸）。
  ///
  /// 画框必须用它，不能用预览控件的尺寸：前者决定坐标含义，后者只决定显示。
  ///
  /// ## 这是硬约定：本尺寸**同时**是 [frames] 里检测框的坐标系
  ///
  /// [rotationDegrees] 描述的是「原始帧需要顺时针转多少度才正立」，
  /// 而**转正这件事由实现方负责**：Android 原生在采样时逐像素逆旋转
  /// （`sampleRgb`），模型的输入本身就是正立图，检测框也就诞生在正立坐标系里。
  ///
  /// 因此 UI 拿到检测框后**不得再旋转一次**。这一点曾经做错过：
  /// UI 既用「已转正的尺寸」构造 [DisplayFit]，又把 [rotationDegrees]
  /// 传给映射函数再转 90°，两处叠加，框整体偏 90° 且不报错。
  /// 现在映射函数已经没有旋转参数，这个错误在类型上写不出来。
  Size get frameSize;

  /// 把原始帧转正所需的**顺时针**旋转角度（0/90/180/270）。
  ///
  /// 必须在接口上，因为它是**平台量**：Android 的 `ImageProxy` 与 iOS 的
  /// `AVCaptureConnection` 会给出不同值。曾经把它硬编码在 UI 里
  /// （`static const int _rotationDegrees = 90`），换个机型或换 iOS 就错。
  int get rotationDegrees;

  /// 检测结果流。实现方负责抽帧与过滤，流里给出的框都已过 [threshold]。
  Stream<VisionFrame> get frames;

  /// 初始化：加载模型、请求权限、启动相机。
  ///
  /// 失败通过返回值的 [VisionSourceStatus.ok] 表达，**不抛异常**。
  Future<VisionSourceStatus> initialize();

  /// 置信度门槛，取值被夹在 [0, 1]。
  double get threshold;
  set threshold(double value);

  /// 诊断快照。不支持的实现（如假数据源）返回 `null`，UI 据此隐藏面板。
  ///
  /// 返回 `Future` 而不是同步值：真实实现的诊断要跨平台通道取。
  Future<VisionDiagnostics?> diagnostics();

  Future<void> dispose();
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
    required this.invalidByReason,
    required this.inputStats,
    required this.outputStats,
    required this.decodeStats,
    required this.bufferState,
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

  /// 无效检测按原因分类的计数：原因 -> 次数。
  ///
  /// 三种原因（分数越界 / 坐标非有限 / 宽高非正）指向完全不同的故障，
  /// 只有总数时无法区分。
  final Map<String, int> invalidByReason;

  /// 输入缓冲的真实统计（min / max / 越界个数 / 前几个值）。
  ///
  /// 与 [outputStats] 配套：只看输出无法区分「输入坏了」与「输出读错了」。
  final String inputStats;

  /// 输出缓冲的真实统计（min / max / 非有限个数 / 前几个值）。
  final String outputStats;

  /// 解码统计：模型**原始输出**的数值范围与**解码后**的分数范围分开报。
  ///
  /// raw 正常而 decoded 异常 → 索引/步长算错；
  /// raw 本身就异常 → 缓冲内容不对。
  final String decodeStats;

  /// 输入/输出缓冲的 position / limit / capacity 快照。
  ///
  /// 用于定位 `IndexOutOfBoundsException: index=0 out of bounds (limit=0)`
  /// 这类错误——「limit=0」只可能来自某个空的缓冲，
  /// 但必须知道是哪一个、以及它为什么是空的。
  final String bufferState;

  /// 模型张量布局，用于核对解码假设。
  final int anchors;
  final int channels;
  final bool transposed;

  @override
  String toString() => 'analyzed=$analyzedFrames errors=$analyzeErrors '
      'skip="$skippedReason" frame=${frameWidth}x$frameHeight '
      'maxScore=${frameMaxScore.toStringAsFixed(3)}';
}

