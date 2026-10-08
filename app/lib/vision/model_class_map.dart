import 'labels.dart';

// 模型本地索引 -> 项目类别真实 id 的映射规则。
//
// ⚠️ **映射表本身不再写在这个文件里**，而是随模型一起下发，见
// `model_manifest.dart` 的 `ModelManifest.modelClassIds`。
//
// 早先它是本文件的一个编译期常量（`modelClassIds = [6, 11, 7]`）。本地开发
// 没问题，但一旦模型可以从服务器下发（云端闭环），**服务端换了类别集而 App
// 不知道**，于是每个框的名字都是错的且不报错。所以它的归属是「跟着模型走的
// 清单」，而不是编译期常量。本文件只保留「怎么映射、怎么拒绝猜测」的规则。

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
    if (identity) return '多類模型：$modelClassCount 類，直接對應類別表';
    final names = ids.map((id) => labelOf(id)?.nameEn ?? 'id$id').join('、');
    return '模型 $modelClassCount 類（$names），映射到項目類別表；'
        '其餘 $unsupportedClassCount 個類別不會出框（未採集數據，非故障）';
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
  required List<int> declared,
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
