import 'dart:async';
// Size 来自 dart:ui。分析器曾提示此导入「多余」（理由：services.dart 已提供
// 全部用到的符号），但那依赖 flutter 内部的再导出链——我核对了
// services.dart 与 asset_bundle.dart 的 export 列表，没有直接看到 Size。
// 这种「删了可能编译失败、留着只是 info」的取舍，保留显式导入更稳：
// 显式导入让依赖关系不依赖上游的再导出细节。
// ignore: unnecessary_import
import 'dart:ui' show Size;

import 'package:flutter/services.dart';

import 'detection.dart';
import 'platform_contract.dart';
import 'model_class_map.dart';
import 'model_manifest.dart';
import 'vision_source.dart';

/// 模型在 **Flutter AssetBundle** 中的 key，与 pubspec.yaml 里声明的一致。
///
/// 注意这与 APK 内的条目路径是两套命名：pubspec/AssetBundle 用
/// `assets/models/detector.tflite`，而 APK 条目是
/// `assets/flutter_assets/assets/models/detector.tflite`。
/// 传给 Android `AssetManager.open()` 时还要去掉开头的 `assets/`
/// （它会自动加前缀）——这个歧义正是我们改用 rootBundle 读取的原因：
/// 实测某些 ROM（Redmi / Android 16 / HyperOS）上 `AssetManager.open()`
/// 读该路径**必然 FileNotFoundException**，而同一次运行里 `assets.list()`
/// 递归又能列出它。
const String defaultModelAssetKey = 'assets/models/detector.tflite';

/// 模型清单的资源 key。清单与模型**一起**下发，缺一不可。
const String defaultModelManifestKey = 'assets/models/detector.json';
const String legacyModelAssetKey = 'assets/models/detector-hk9.tflite';
const String legacyModelManifestKey = 'assets/models/detector-hk9.json';

/// 平台原生视觉能力（Android CameraX + LiteRT）。
///
/// ## 它现在真正实现了 [VisionSource]
///
/// 改造前本类**没有**实现该接口，UI 里通篇是 `_platform.xxx` 与
/// `_mock?.xxx` 两套并行分支。后果是换平台要做两遍，而且没有任何机制保证
/// 两个实现行为一致。现在它 implements [VisionSource]，
/// 由 `test/vision_source_contract_test.dart` 断言。
///
/// ## 职责边界
///
/// 1. **把原生回包翻成 Dart 对象**，并做防御式解析——原生是另一个语言写的，
///    少一个键、类型不对都不该让 App 崩，只该退化成「本帧无结果」。
/// 2. **暴露干净状态**（[initialize] 的返回值、[diagnostics]）给 UI。
///
/// 所有字符串键名都取自 [VisionKeys]，不在这里另写一份。
class PlatformVision implements VisionSource {
  PlatformVision({
    MethodChannel? method,
    EventChannel? events,
    this.rotationDegrees = 90,
    this.modelAssetKey = defaultModelAssetKey,
    this.modelManifestKey = defaultModelManifestKey,
  }) : _method = method ?? const MethodChannel(kVisionChannel),
       _events = events ?? const EventChannel(kFrameChannel);

  final MethodChannel _method;
  final EventChannel _events;
  final String modelAssetKey;
  final String modelManifestKey;

  /// 把原始帧转正所需的顺时针角度。
  ///
  /// 默认 90：Android 后置相机在竖屏下输出横屏帧，需顺时针转 90° 才正立。
  /// 做成构造参数而不是常量：它是**平台量**，iOS 的 AVFoundation 与不同机型
  /// 会给出不同值。曾经它被硬编码在 UI 里，换个机型就会整体错位。
  @override
  final int rotationDegrees;

  Stream<VisionFrame>? _frames;
  bool _loaded = false;
  bool _ready = false;
  bool _disposed = false;
  Set<int> _acceptedClassIds = const <int>{};
  String? _loadError;
  int _inputSize = 0;
  int _modelClassCount = 0;
  String? _startError;

  /// 传给原生的索引映射表（空表 = 不需要映射）。initialize() 里算出来后写入。
  List<int> _classIds = const <int>[];
  double _threshold = 0.30;

  /// 最近一帧的**原始**尺寸（旋转之前），用于推出 [frameSize]。
  int _rawFrameWidth = 0;
  int _rawFrameHeight = 0;

  /// 模型输出维度（原始，未偏移）。单类模型这里是 1，多类模型是 24。
  int get modelClassCount => _modelClassCount;

  /// 传给原生的类别 id 偏移（0 表示不偏移）。
  List<int> get classIds => _classIds;

  /// 模型输入边长。
  int get inputSize => _inputSize;

  /// 模型是否已成功加载。
  bool get isReady => _ready;

  /// 最近一次失败原因。为空表示没有失败。
  String? get error => _loadError;

  @override
  String get displayName => '相機';

  /// **旋转之后**的帧尺寸——归一化坐标的坐标系。
  ///
  /// 优先用真实帧尺寸；还没收到帧时用默认的 1280x720 占位，
  /// 这样首帧到达之前画框不会 NaN，也不会画在错误的位置上。
  @override
  Size get frameSize {
    final w = _rawFrameWidth > 0 ? _rawFrameWidth : 1280;
    final h = _rawFrameHeight > 0 ? _rawFrameHeight : 720;
    return rotationDegrees % 180 == 90
        ? Size(h.toDouble(), w.toDouble())
        : Size(w.toDouble(), h.toDouble());
  }

  @override
  double get threshold => _threshold;

  /// 写入即夹紧并**同时推给原生**。
  ///
  /// 阈值只在原生侧生效（低分框不过通道，省掉每帧的序列化开销），
  /// Dart 侧不再重复过滤——两处各过滤一次时，不一致的表现是
  /// 「滑动条不生效」或「框数对不上」，且不报错。
  @override
  set threshold(double value) {
    _threshold = value.clamp(0.0, 1.0);
    unawaited(_pushThreshold(_threshold));
  }

  /// 检测结果流。只允许订阅一次。
  @override
  Stream<VisionFrame> get frames => _frames ??= _events
      .receiveBroadcastStream()
      .where((event) => _ready && event is Map)
      .map((event) => _parseFrame(event as Map));

  /// 启动预览、请求权限、加载模型。返回可展示的结果，**不抛异常**。
  @override
  Future<VisionSourceStatus> initialize() async {
    const cancelled = VisionSourceStatus(ok: false, message: '辨識已取消，請重新開始');
    if (_disposed) return cancelled;
    _ready = false;
    _acceptedClassIds = const <int>{};
    // 1) 订阅结果流（必须在相机启动前，否则会丢首帧）
    _frames ??= _events
        .receiveBroadcastStream()
        .where((event) => _ready && event is Map)
        .map((event) => _parseFrame(event as Map));

    // 2) 请求权限并启动原生相机预览
    final started = await _startPreview();
    if (_disposed) return cancelled;
    if (!started) {
      return VisionSourceStatus(
        ok: false,
        message: '相機未啟動',
        error: _startError ?? '請檢查相機權限或其他程式是否正在使用相機。',
      );
    }

    // 3) 读**模型清单**。清单与模型同源下发，里面写着「本地索引 -> 真实 id」。
    //
    //    为什么不能像以前那样在代码里写一个常量：模型将来要从服务器下发，
    //    服务端一旦换类别集而 App 不知道，就会把每个框标成别的类且不报错。
    //    所以这份信息必须跟着模型走，App 只负责校验，不猜。
    final parsed = parseModelManifest(
      await rootBundle.loadString(modelManifestKey),
    );
    if (!parsed.ok) {
      return VisionSourceStatus(
        ok: false,
        message: '模型清單有問題',
        error: parsed.error,
      );
    }
    final manifest = parsed.manifest!;
    if (_disposed) return cancelled;

    // Load once with the declared mapping. An unmapped warm-up interpreter can
    // emit local indices (0/5) as legacy app IDs (entrance/railing).
    final ok = await _loadModel(manifest.modelClassIds);
    if (_disposed) return cancelled;
    final mapping = ok
        ? resolveMapping(
            modelClassCount: _modelClassCount,
            declared: manifest.modelClassIds,
          )
        : null;
    if (ok &&
        (mapping == null || _modelClassCount != manifest.modelClassCount)) {
      return const VisionSourceStatus(
        ok: false,
        message: '模型與清單不符',
        error: '模型類別數或映射不符，已停止輸出辨識結果。',
      );
    }
    final mappingFinal = mapping;

    if (!ok) {
      return VisionSourceStatus(ok: false, message: '模型未加載', error: _loadError);
    }
    if (!started) {
      // 模型好了但相机没起来：仍是失败，但要区分原因，
      // 否则用户会以为是模型问题。
      return VisionSourceStatus(
        ok: false,
        message: '相機未啟動',
        error: _startError ?? '模型已加載，但原生相機未啟動：可能未授予權限，或被其他程序佔用',
      );
    }
    _acceptedClassIds = mapping!.identity
        ? Set<int>.from(List<int>.generate(_modelClassCount, (i) => i))
        : mapping.ids.toSet();
    _ready = true;
    return VisionSourceStatus(
      ok: true,
      message:
          '模型已加載（類別數 $_modelClassCount'
          '，輸入 $_inputSize）'
          '${mappingFinal != null ? "；${mappingFinal.describe()}" : ""}',
    );
  }

  /// 请求原生侧申请权限并启动相机预览。返回是否真的启动了。
  ///
  /// 权限申请在原生侧完成：Dart 无法自己拿到 Android 的运行时权限，
  /// 而原生若只在插件构造时检查一次权限，用户授权后会一直停在「无权限」，
  /// 相机永不启动——表现为一片黑，且没有任何报错。
  ///
  /// 加超时的原因：权限对话框若因 Activity 重建等原因没有回调，
  /// Future 会永不完成。宁可超时给出明确提示，也不要卡在「正在初始化」。
  Future<bool> _startPreview() async {
    try {
      final reply = await _method
          .invokeMethod<Map<Object?, Object?>>(VisionMethods.startPreview)
          .timeout(const Duration(seconds: 60));
      _startError = reply?['error'] as String?;
      return reply?['started'] == true;
    } on TimeoutException {
      _startError = '等待相機權限或啟動逾時';
      return false;
    } on PlatformException catch (e) {
      _startError = '${e.code}: ${e.message ?? "相機平台錯誤"}';
      return false;
    } on MissingPluginException {
      // 平台插件未註冊時回傳可操作的失敗狀態，而不是讓初始化拋出。
      _startError = '目前平台尚未註冊相機視覺插件';
      return false;
    }
  }

  /// 诊断快照。不支持时返回 `null`（本实现支持）。
  @override
  Future<VisionDiagnostics?> diagnostics() async {
    try {
      final r = await _method.invokeMethod<Map<Object?, Object?>>(
        VisionMethods.status,
      );
      if (r == null) return null;
      return VisionDiagnostics(
        modelReady: r[VisionKeys.ready] == true,
        modelPath: r[VisionKeys.modelPath] as String?,
        inputSize: _asInt(r[VisionKeys.inputSize]) ?? 0,
        modelClassCount: _asInt(r[VisionKeys.classes]) ?? 0,
        analyzedFrames: _asInt(r['analyzedFrames']) ?? 0,
        analyzeErrors: _asInt(r['analyzeErrors']) ?? 0,
        skippedReason: (r['skippedReason'] as String?) ?? '',
        analyzeError: (r['analyzeError'] as String?) ?? '',
        frameWidth: _asInt(r['frameWidth']) ?? 0,
        frameHeight: _asInt(r['frameHeight']) ?? 0,
        frameFormat: (r['frameFormat'] as String?) ?? '',
        frameMaxScore: _asDouble(r['frameMaxScore']) ?? 0,
        frameMinScore: _asDouble(r['frameMinScore']) ?? 0,
        detectionCount: _asInt(r['detectionCount']) ?? 0,
        invalidDetections: _asInt(r['invalidDetections']) ?? 0,
        invalidSample: (r['invalidSample'] as String?) ?? '',
        invalidByReason: _asIntMap(r['invalidByReason']),
        inputStats: (r['inputStats'] as String?) ?? '',
        outputStats: (r['outputStats'] as String?) ?? '',
        decodeStats: (r['decodeStats'] as String?) ?? '',
        bufferState: (r['bufferState'] as String?) ?? '',
        anchors: _asInt(r['anchors']) ?? 0,
        channels: _asInt(r['channels']) ?? 0,
        transposed: r['transposed'] == true,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> _pushThreshold(double value) async {
    try {
      await _method.invokeMethod<void>(
        VisionMethods.setThreshold,
        <String, Object>{VisionKeys.threshold: value},
      );
    } on PlatformException {
      // 原生侧未实现该方法时静默忽略：滑动条仍可用，只是不省序列化开销。
    } on MissingPluginException {
      // 平台插件未註冊時忽略閾值更新。
    }
  }

  /// 加载模型。
  ///
  /// ## 为什么由 Dart 读资源再交给原生
  ///
  /// 实测原生 `AssetManager.open()` 在部分 ROM 上读不到 `flutter_assets`
  /// 下的资源。Flutter 自己的资源系统是可靠的（`AssetManifest.bin` 里明确
  /// 列有该 key），所以改为：**Dart 用 rootBundle 读出字节 -> 写入应用私有
  /// 目录 -> 原生读文件**，彻底绕开 AssetManager 的路径歧义。
  ///
  /// 代价：启动时多一次写盘。用「已存在且大小一致就跳过」避免重复写。
  Future<bool> _loadModel(List<int> classIds) async {
    _classIds = classIds;

    // 非空类型：_materializeModelToDisk 失败时抛异常，不返回 null。
    // 之前写成 `String?` 并在下面判 `filePath == null`，那条分支永远是死代码
    // （分析器直接报了 unnecessary_null_comparison + dead_code）。
    // 用非空类型把这个不可能状态从类型上排除掉。
    final String filePath;
    try {
      filePath = await _materializeModelToDisk(modelAssetKey);
    } catch (e) {
      _loaded = false;
      _loadError = '把模型寫入應用目錄失敗：${e.runtimeType}: $e';
      return false;
    }

    if (_disposed) return false;
    try {
      final reply = await _method.invokeMethod<Map<Object?, Object?>>(
        VisionMethods.loadModel,
        <String, Object>{
          VisionKeys.model: filePath,
          VisionKeys.classIds: classIds,
        },
      );
      if (_disposed) return false;
      _loaded = reply?[VisionKeys.loaded] == true;
      _modelClassCount = _asInt(reply?[VisionKeys.classes]) ?? 0;
      _inputSize = _asInt(reply?[VisionKeys.inputSize]) ?? 0;
      _loadError = _loaded ? null : (reply?['error'] as String? ?? '未知原因');
      return _loaded;
    } on PlatformException catch (e) {
      _loaded = false;
      _loadError = '${e.code}: ${e.message}';
      return false;
    } on MissingPluginException {
      _loaded = false;
      _loadError = '目前平台尚未實現視覺插件（iOS 待補，見環境文檔 §6.4）';
      return false;
    }
  }

  Future<String> _materializeModelToDisk(String assetKey) async {
    final dir = await _method.invokeMethod<String>(VisionMethods.modelDir);
    if (dir == null || dir.isEmpty) {
      throw StateError('原生未返回可寫的模型目錄');
    }
    final data = await rootBundle.load(assetKey);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );

    final target = '$dir/${assetKey.split('/').last}';
    // 已存在且大小一致就跳过写盘：模型约 10 MB，每次启动都写没必要。
    //
    // 注意类型：原生返回 kotlin Long，平台通道映射成 Dart int。
    // 泛型若写死 <int> 而原生返回别的整数类型，会**静默得到 null**，
    // 于是每次启动都重写——所以要显式处理 null 并把类型放宽。
    final Object? existingRaw = await _method.invokeMethod<Object?>(
      VisionMethods.fileSize,
      <String, Object>{VisionKeys.path: target},
    );
    final existing = existingRaw is num ? existingRaw.toInt() : -1;
    if (existing == bytes.length) {
      return target;
    }
    await _method.invokeMethod<void>(VisionMethods.writeFile, <String, Object>{
      VisionKeys.path: target,
      VisionKeys.bytes: bytes,
    });
    return target;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ready = false;
    try {
      await _method.invokeMethod<void>(VisionMethods.release);
    } on PlatformException {
      // 释放失败不影响退出。
    } on MissingPluginException {
      // 同上。
    }
    _loaded = false;
  }

  VisionFrame _parseFrame(Map<Object?, Object?> raw) {
    final w = _asInt(raw[VisionKeys.frameWidth]) ?? 0;
    final h = _asInt(raw[VisionKeys.frameHeight]) ?? 0;
    if (w > 0 && h > 0) {
      _rawFrameWidth = w;
      _rawFrameHeight = h;
    }
    return VisionFrame(
      detections: _parseDetections(raw[VisionKeys.detections])
          .where((d) => _acceptedClassIds.contains(d.id))
          .toList(growable: false),
      inferenceMs: _asDouble(raw[VisionKeys.inferenceMs]) ?? 0,
      frameWidth: w,
      frameHeight: h,
    );
  }

  /// 防御式解析：[Detection.fromMap] 对缺键/错类型返回 null 并在此被过滤，
  /// 因此单个坏框不会丢掉整帧结果。
  ///
  /// 这里**不再按阈值过滤**——阈值已在原生侧生效（低分框不过通道）。
  /// 两处各过滤一次时，不一致的表现是「滑动条不生效」或「框数对不上」，
  /// 且不报错。过滤只保留一处。
  static List<Detection> _parseDetections(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map(Detection.fromMap)
        .whereType<Detection>()
        .where((d) => !d.isDegenerate)
        .toList(growable: false);
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is double && v.isFinite) return v.round();
    return null;
  }

  static double? _asDouble(Object? v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    return null;
  }

  /// 把原生回传的 `Map<Object?, Object?>` 转成 `Map<String, int>`，逐项防御式解析。
  static Map<String, int> _asIntMap(Object? raw) {
    if (raw is! Map) return const <String, int>{};
    final out = <String, int>{};
    raw.forEach((k, v) {
      if (k is! String) return;
      final n = _asInt(v);
      if (n != null) out[k] = n;
    });
    return out;
  }
}
