import 'dart:convert';

import 'labels.dart';
import 'model_class_map.dart';

/// 模型清单：**模型下发的单位不是单个 .tflite 文件，而是"模型 + 它的类别映射"**。
///
/// ## 为什么必须有这个
///
/// TFLite 里**没有**「这个模型是用哪些 class-id 训的」这个元数据。以前这份信息
/// 写死在 `model_class_map.dart` 的 `modelClassIds` 常量里——本地开发没问题，
/// 但一旦模型可以从服务器下发（云端闭环），**服务端换了类别集而 App 不知道**，
/// 于是每个框的名字都是错的，**而且不报错**。这是本项目反复吃亏的那一类故障。
///
/// 所以：**清单与模型一起下发，id 从训练数据集的 `classes.json` 生成**，
/// 不手写、不推断。App 只做校验，不猜。
///
/// ## 清单字段（由 `scripts/export_tflite.py` 生成）
///
/// ```json
/// {
///   "format": 1,
///   "version": "2026-09-30.1",
///   "file": "detector.tflite",
///   "bytes": 2871365,
///   "sha256": "…",
///   "inputSize": 416,
///   "modelClassCount": 3,
///   "modelClassIds": [6, 11, 7],
///   "trainedAt": "2026-09-30",
///   "metrics": { "map50": 0.744 }
/// }
/// ```
class ModelManifest {
  const ModelManifest({
    required this.format,
    required this.version,
    required this.file,
    required this.modelClassCount,
    required this.modelClassIds,
    required this.inputSize,
    this.bytes,
    this.sha256,
    this.trainedAt,
    this.map50,
  });

  /// 清单格式版本。将来字段变了要升版本，**旧 App 读新清单必须报错而不是忽略未知字段**。
  final int format;
  final String version;

  /// 模型文件名（与清单同目录）。
  final String file;

  /// 模型输出的类别数。
  final int modelClassCount;

  /// 本地索引 -> 项目类别真实 id。**这是清单存在的理由。**
  final List<int> modelClassIds;

  /// 模型输入边长。
  final int inputSize;

  /// 文件字节数（可选，用于下载完整性初筛）。
  final int? bytes;

  /// 文件哈希（可选，用于校验下载是否完整）。
  final String? sha256;

  final String? trainedAt;
  final double? map50;

  /// 转成映射对象。清单已校验过，所以这里一定成功。
  ModelClassMapping toMapping() => ModelClassMapping(
        modelClassCount: modelClassCount,
        ids: modelClassIds.isEmpty
            ? const <int>[]
            : List<int>.unmodifiable(modelClassIds),
      );

  /// 给界面/日志用的一句话。
  String describe() {
    final names = modelClassIds
        .map((id) => labelOf(id)?.nameEn ?? 'id$id')
        .join('、');
    return '模型清單 $version：$modelClassCount 類（$names），'
        '輸入 $inputSize'
        '${map50 != null ? "，mAP50 ${map50!.toStringAsFixed(3)}" : ""}';
  }
}

/// 清单解析结果。`manifest == null` 时 `error` 一定有内容——
/// 不返回"半个清单"，避免调用方拿到部分字段就往下走。
class ManifestParseResult {
  const ManifestParseResult.ok(this.manifest) : error = null;
  const ManifestParseResult.fail(this.error) : manifest = null;

  final ModelManifest? manifest;
  final String? error;

  bool get ok => manifest != null;
}

/// 解析并**严格校验**清单。任何一项不合法都返回失败原因，绝不降级猜一个。
///
/// 校验项与理由：
/// - `format` 必须为 1：将来字段变了，旧 App 读到新清单必须报错而非忽略未知字段
/// - `modelClassIds.length == modelClassCount`：长度不符说明清单与模型不同源
/// - 每个 id 都必须在类别表内：越界 id 会让 `labelOf` 返回 null
/// - id 不重复：重复意味着漏了一类
///
/// `sha256` 只校验格式（长度 64、十六进制）；真正的哈希比对在读取文件字节时做，
/// 因为这里拿不到文件内容。
ManifestParseResult parseModelManifest(String text) {
  Object? raw;
  try {
    raw = jsonDecode(text);
  } catch (e) {
    return ManifestParseResult.fail('模型清單不是合法 JSON：$e');
  }
  if (raw is! Map) {
    return ManifestParseResult.fail('模型清單頂層應為對象，實際 ${raw.runtimeType}');
  }

  int? asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
  final format = asInt(raw['format']);
  if (format != 1) {
    return ManifestParseResult.fail(
        '模型清單 format=$format，本版 App 只認 format=1。'
        '（格式變了必須報錯，不能忽略未知欄位繼續跑）');
  }

  final version = raw['version'];
  if (version is! String || version.isEmpty) {
    return ManifestParseResult.fail('模型清單缺 version');
  }
  final file = raw['file'];
  if (file is! String || file.isEmpty) {
    return ManifestParseResult.fail('模型清單缺 file');
  }
  final inputSize = asInt(raw['inputSize']);
  if (inputSize == null || inputSize <= 0) {
    return ManifestParseResult.fail('模型清單 inputSize 非法：${raw['inputSize']}');
  }
  final count = asInt(raw['modelClassCount']);
  if (count == null || count <= 0) {
    return ManifestParseResult.fail('模型清單 modelClassCount 非法：${raw['modelClassCount']}');
  }

  final idsRaw = raw['modelClassIds'];
  if (idsRaw is! List) {
    return ManifestParseResult.fail('模型清單缺 modelClassIds 陣列');
  }
  final ids = <int>[];
  for (final v in idsRaw) {
    final n = asInt(v);
    if (n == null) {
      return ManifestParseResult.fail('modelClassIds 裏有非整數：$v');
    }
    ids.add(n);
  }

  // ★ 关键校验：清单必须与模型自洽，否则映射必然错位。
  if (ids.isEmpty) {
    if (count != kNumClasses) {
      return ManifestParseResult.fail(
          'modelClassIds 為空表示「輸出即真實 id」，但模型是 $count 類、'
          '類別表是 $kNumClasses 類：二者不等，空表不成立');
    }
  } else {
    if (ids.length != count) {
      return ManifestParseResult.fail(
          'modelClassIds 有 ${ids.length} 項，而 modelClassCount=$count：長度必須一致');
    }
    for (final id in ids) {
      if (labelOf(id) == null) {
        return ManifestParseResult.fail(
            'modelClassIds 裏有超出類別表的 id：$id（類別表 $kNumClasses 類）');
      }
    }
    if (ids.toSet().length != ids.length) {
      return ManifestParseResult.fail('modelClassIds 裏有重複 id：$ids（重複意味著漏了一類）');
    }
  }

  final sha = raw['sha256'];
  if (sha != null) {
    if (sha is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      return ManifestParseResult.fail('模型清單 sha256 格式不對（應為 64 位小寫十六進制）');
    }
  }

  double? asDouble(Object? v) => v is num ? v.toDouble() : null;

  return ManifestParseResult.ok(ModelManifest(
    format: format!,
    version: version,
    file: file,
    modelClassCount: count,
    modelClassIds: List<int>.unmodifiable(ids),
    inputSize: inputSize,
    bytes: asInt(raw['bytes']),
    sha256: sha as String?,
    trainedAt: raw['trainedAt'] is String ? raw['trainedAt'] as String : null,
    map50: asDouble(raw['map50']),
  ));
}
