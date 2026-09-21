import 'labels.dart';

/// 单类模型与项目 24 类类别表之间的映射。
///
/// ## 为什么需要它
///
/// 为了先跑通「一个类能用的 demo」，训练了一个**单类**模型（只认垃圾桶）。
/// 它的输出只有 1 个类别，id 固定为 0。而 App 的类别表 `kLabels` 有 24 类，
/// `kLabels[0]` 是 `footbridge_entrance`（天橋入口）。
///
/// 如果直接把模型输出的 0 拿去查表，界面会把垃圾桶标成「天橋入口」——
/// **框是对的、名字是错的**，而且不报任何错。这是本项目最该防的一类故障：
/// 类别索引错位。
///
/// ## 约定
///
/// 单类数据集由 `scripts/build_single_class_dataset.py` 生成，它在
/// `classes.json` 里留下 `original_id`（本项目中 `bin` = 7）与 `name_en`。
/// App 侧把这个 `original_id` 传给原生，原生在回传检测框时**加上该偏移**，
/// 于是 Dart 之后的代码（画框、播报、类别表查询）**一行都不用改**。
///
/// 映射放在原生侧而不是 Dart 侧，是因为原生已经在做「按形状反推类别数」，
/// 让它一并完成偏移最不容易漏。
class SingleClassMapping {
  const SingleClassMapping({
    required this.modelClassCount,
    required this.originalClassId,
    required this.modelClassName,
  });

  /// 模型输出的类别数（单类模型为 1）。
  final int modelClassCount;

  /// 该单类在项目类别表中的原始 id（垃圾桶 = 7）。
  final int originalClassId;

  /// 模型类别的英文名，仅用于界面提示。
  final String modelClassName;

  /// 是否是单类模型（需要偏移映射）。
  bool get isSingleClass => modelClassCount == 1;

  /// 偏移量：原生把它加到模型输出的 id 上。
  int get classOffset => originalClassId;

  /// 该模型无法识别的类别数（界面上要写明，否则会被当成模型坏了）。
  int get unsupportedClassCount => kNumClasses - modelClassCount;

  /// 给界面用的一句话说明。
  String describe() => isSingleClass
      ? '单类模型：只识别「$modelClassName」，'
          '其余 $unsupportedClassCount 个类别不会出框（未采集数据，非故障）'
      : '多类模型：$modelClassCount 类';

  /// 当前单类模型对应的项目类别。若 id 越界返回 null。
  Label? get projectLabel => labelOf(originalClassId);
}

/// 由「模型报告的类别数」判断该怎么映射。
///
/// - 模型类别数 == 项目类别数 -> 多类模型，偏移 0，按原样查表
/// - 模型类别数 == 1          -> 单类模型，需要外部告诉我们是哪一类
/// - 其他                     -> 不认识的形状，返回 null（调用方应报错而非猜）
SingleClassMapping? resolveMapping({
  required int modelClassCount,
  int? singleClassOriginalId,
  String singleClassName = '',
}) {
  if (modelClassCount == kNumClasses) {
    return SingleClassMapping(
      modelClassCount: modelClassCount,
      originalClassId: 0,
      modelClassName: '',
    );
  }
  if (modelClassCount == 1) {
    if (singleClassOriginalId == null) return null;
    if (labelOf(singleClassOriginalId) == null) return null;
    return SingleClassMapping(
      modelClassCount: 1,
      originalClassId: singleClassOriginalId,
      modelClassName: singleClassName.isEmpty
          ? (labelOf(singleClassOriginalId)?.nameEn ?? '')
          : singleClassName,
    );
  }
  return null;
}
