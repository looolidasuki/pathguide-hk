/// 平台通道契约 —— 本文件是原生接口的**唯一事实源**。
///
/// ## 为什么所有字符串都集中在这里
///
/// 通道名或回包键名在 Kotlin 与 Swift 两侧不一致时，表现为
/// **「调用静默无结果」**：`invokeMethod` 拿不到回包，Dart 侧以为没有检测结果，
/// 两端都不抛异常、日志里也没有线索。这类 bug 极难定位。
///
/// 所以二条纪律：
/// 1. Kotlin 与 Swift 实现**不得各写各的字面量**，必须引用这里的同一套键名；
/// 2. Dart 侧对回包**防御式解析**，缺键或类型不符都退化为「无结果」，
///    避免某个平台实现的差异把整个 App 打崩。
///
/// 对应原生实现位置：
/// - Android: `android/app/src/main/kotlin/hk/pathguide/pathguide/VisionPlugin.kt`
/// - iOS:     `ios/Runner/VisionPlugin.swift`（待实现，见环境文档 §6.4）
library;

/// 平台通道名。改动此值必须同时改动两端原生代码。
const String kVisionChannel = 'hk.pathguide/vision';

/// 逐帧检测结果的 EventChannel 名。原生侧主动推送，Dart 侧订阅。
///
/// 与 [kVisionChannel] 分开是刻意的：实时结果流是**高频**的，
/// 走 EventChannel 避免 Dart 每帧发一次请求（那会让帧率减半）。
const String kFrameChannel = 'hk.pathguide/vision/frame';

/// 相机预览的平台视图类型名。必须与原生 `registerViewFactory` 的注册名一致——
/// 不一致时表现为**一块空白**，两端都不报错。
const String kVisionPreviewViewType = 'hk.pathguide/vision/preview';

/// 原生方法名。
abstract final class VisionMethods {
  /// 加载模型。`{model: String}` -> `{loaded: bool, classes: int, inputSize: int}`
  static const String loadModel = 'loadModel';

  /// 单帧推理。
  /// 入参见 [VisionKeys]：`{bytes, frameWidth, frameHeight, rotationDegrees, threshold}`
  /// 回包：`{detections: [{id, score, cx, cy, w, h}, ...], inferenceMs: double}`
  static const String detect = 'detect';

  /// 释放解释器，切后台或退出时调用。
  static const String release = 'release';

  /// 更新原生侧阈值。入参 `{threshold: double}`。
  ///
  /// 阈值必须在**原生侧**生效，否则低分框仍会跨通道传过来，
  /// 白白消耗每帧的序列化开销。
  static const String setThreshold = 'setThreshold';

  /// 请求原生侧启动相机预览。回包 `{started: bool}`。
  ///
  /// **必须在 Dart 侧拿到相机权限之后调用。** 权限是运行时申请的，
  /// 若原生只在插件构造时检查一次，用户授权后原生仍停留在「无权限」，
  /// 相机永不启动——表现为一片黑，且没有任何报错。
  static const String startPreview = 'startPreview';

  /// 原生侧能力与状态查询：`{ready: bool, modelPath: String?, inputSize: int?}`
  static const String status = 'status';
}

/// 通道回包与入参的键名。
///
/// 键名写错同样不会有任何报错——只会得到 `null`。
abstract final class VisionKeys {
  // ---- loadModel ----
  static const String model = 'model';
  static const String loaded = 'loaded';
  static const String classes = 'classes';
  static const String inputSize = 'inputSize';

  // ---- detect 入参 ----
  /// 帧的原始像素字节。Android 为 **NV21**（`Uint8List`，长度 = w*h*3/2）。
  static const String bytes = 'bytes';

  /// 原始帧尺寸。注意：**不是**预览尺寸，也**不是**模型输入尺寸。
  static const String frameWidth = 'frameWidth';
  static const String frameHeight = 'frameHeight';

  /// 把原始帧转成正立所需顺时针旋转的角度：0 / 90 / 180 / 270。
  ///
  /// 由 Dart 侧算出并传入，因为旋转由「相机传感器朝向 + 设备方向」决定，
  /// Dart 能从 `camera` 插件拿到这个信息；原生侧不该再猜一次。
  static const String rotationDegrees = 'rotationDegrees';

  /// 置信度门槛。低于此值的框原生侧就丢弃，避免把大量低分框搬过通道。
  static const String threshold = 'threshold';

  // ---- detect 回包 ----
  static const String detections = 'detections';
  static const String inferenceMs = 'inferenceMs';

  // ---- 单个检测框 ----
  /// 类别 id，对应 `labels.dart` 的 `kLabels` 下标。
  static const String id = 'id';
  static const String score = 'score';

  /// 归一化中心点坐标与宽高（YOLO 格式），取值 [0, 1]，
  /// 坐标系为**旋转到位之后的原始帧**。
  ///
  /// 之所以只传归一化坐标而不传像素：归一化值与本帧的分辨率解耦，
  /// Dart 侧再结合 [DisplayFit] 映射到屏幕，两端都不需要知道对方的像素尺寸。
  static const String cx = 'cx';
  static const String cy = 'cy';
  static const String w = 'w';
  static const String h = 'h';

  // ---- status ----
  static const String ready = 'ready';
  static const String modelPath = 'modelPath';
}
