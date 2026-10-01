import 'labels.dart';

/// **当前放进 App 的那个模型**，它的每个输出类别对应项目类别表里的哪一类。
///
/// 顺序 = 模型输出的本地索引顺序；值 = 该项目类别表 `kLabels` 里的真实 id。
/// 因此 `modelClassIds[0]` 是「模型第 0 类其实是哪一类」。
///
/// 改这里 = 换模型。取值必须与训练时数据集 `classes.json` 里各类的
/// `original_id` **顺序一致**（`scripts/build_multiclass_dataset.py` 会写出来）。
///
/// ## 为什么必须显式声明
///
/// TFLite 里**没有**「这个模型是用哪些 class-id 训的」这个元数据，
/// App 只能靠这里声明。**声明错了不会报错**，只会把垃圾桶标成别的类别名——
/// 框对、名字错、不报错。所以：
///
/// - 下面的测试断言它与数据集的 `classes.json` 一致；
/// - `scripts/export_tflite.py` 也在导出时交叉核对长度与取值。
///
/// ## 与「单类偏移」的区别
///
/// 早先只有一个类，用「加一个常数偏移」就够了。3 类以上偏移表达不了
/// （除非恰好连续），所以改成映射表——它同时覆盖单类场合（长度 1）。
const List<int> modelClassIds = <int>[6, 11, 7]; // pedestrian, bicycle, bin

/// 模型与项目类别表之间的映射。
///
/// ## 为什么需要它
///
/// YOLO 只接受 `0..nc-1` 的本地索引作为标签（写真实 id 会让整个数据集被判
/// 「标签格式非法」而全部丢弃）。所以数据集与模型都只说本地索引，
/// 真实 id 由这里映射回去。
///
/// 如果直接把模型输出的本地索引拿去查表：模型第 0 类是垃圾桶，
/// 而 `kLabels[0]` 是 `footbridge_entrance`（天橋入口）——
/// **框是对的、名字是错的**，且不报任何错。
///
/// ## 约定
///
/// 映射放在**原生侧**执行（原生已经在按形状反推类别数，让它一并完成映射
/// 最不容易漏），Dart 之后的代码（画框、播报、查表）一行都不用改，
/// 收到的 id 就已经是真实 id。
class ModelClassMapping {
  const ModelClassMapping({
    required this.modelClassCount,
    required this.ids,
  });

  /// 模型输出的类别数。
  final int modelClassCount;

  /// 本地索引 -> 真实 id。**空表表示不需要映射**（模型类别数已等于类别表）。
  final List<int> ids;

  /// 模型类别数已经等于项目类别表，输出即真实 id，不需要映射。
  bool get identity => ids.isEmpty;

  /// 本地索引 -> 真实 id。越界返回 null（调用方应丢弃该框，而不是猜）。
  int? appIdFor(int localId) {
    if (identity) {
      return (localId >= 0 && localId < kNumClasses) ? localId : null;
    }
    if (localId < 0 || localId >= ids.length) return null;
    return ids[localId];
  }

  /// 该模型无法识别的类别数（界面上要写明，否则会被当成模型坏了）。
  int get unsupportedClassCount => kNumClasses - modelClassCount;

  /// 给界面用的一句话说明。
  String describe() {
    if (identity) return '多类模型：$modelClassCount 类，直接对应类别表';
    final names = ids.map((id) => labelOf(id)?.nameEn ?? 'id$id').join('、');
    return '模型 $modelClassCount 类（$names），映射到项目类别表；'
        '其余 $unsupportedClassCount 个类别不会出框（未采集数据，非故障）';
  }
}

/// 由「模型报告的类别数」+ 声明表判断该怎么映射。
///
/// - 模型类别数 == 项目类别数 -> 不需要映射（identity）
/// - 否则要求声明表长度**恰好等于**模型类别数，且每个 id 都在类别表内
/// - 其他情况返回 null：调用方应当**报错**，而不是猜一个映射
///
/// 返回 null 是刻意的保守设计：猜错的映射不会崩，只会安静地把框标错类，
/// 这类错误在训练和演示里都极难发现。
ModelClassMapping? resolveMapping({
  required int modelClassCount,
  List<int> declared = modelClassIds,
}) {
  if (modelClassCount == kNumClasses) {
    return ModelClassMapping(
      modelClassCount: modelClassCount,
      ids: const <int>[],
    );
  }
  if (declared.isEmpty) return null;
  if (declared.length != modelClassCount) return null;
  for (final id in declared) {
    if (labelOf(id) == null) return null;
  }
  if (declared.toSet().length != declared.length) return null; // 有重复
  return ModelClassMapping(
    modelClassCount: modelClassCount,
    ids: List<int>.unmodifiable(declared),
  );
}
