import 'dart:async';

import 'package:flutter/services.dart';

import 'detection.dart';
import 'platform_contract.dart';
import 'vision_source.dart';

/// 模型在 **Flutter AssetBundle** 中的 key，与 pubspec.yaml 里声明的一致。
///
/// 注意这与 APK 内的条目路径是两套命名：pubspec/AssetBundle 用
/// `assets/models/detector.tflite`，而 APK 条目是
/// `assets/flutter_assets/assets/models/detector.tflite`。
/// 传给 Android `AssetManager.open()` 时还要去掉开头的 `assets/`
/// （它会自动加前缀）——这个歧义正是我们改用 rootBundle 读取的原因。
const String defaultModelAssetKey = 'assets/models/detector.tflite';

/// 平台原生视觉能力（Android CameraX + LiteRT）。
///
/// ## 这一层只做两件事
///
/// 1. **把原生回包翻成 Dart 对象**，并做防御式解析——原生是另一个语言写的，
///    少一个键、类型不对都不该让 App 崩，只该退化成「本帧无结果」。
/// 2. **暴露一个干净的状态**（[isReady] / [error] / [frameSize]）给 UI。
///
/// 所有字符串键名都取自 [VisionKeys]，不在这里另写一份。
class PlatformVision {
  PlatformVision({
    MethodChannel? method,
    EventChannel? events,
  })  : _method = method ?? const MethodChannel(kVisionChannel),
        _events = events ?? const EventChannel(kFrameChannel);

  final MethodChannel _method;
  final EventChannel _events;

  Stream<VisionFrame>? _frames;
  bool _loaded = false;
  String? _error;
  int _numClasses = 0;
  int _inputSize = 0;

  /// 模型是否已成功加载。
  bool get isReady => _loaded;

  /// 最近一次失败原因。为空表示没有失败。
  String? get error => _error;

  /// 模型输出维度。与 `kNumClasses` 不一致即为模型与类别表不匹配。
  int get numClasses => _numClasses;

  /// 模型输入边长。
  int get inputSize => _inputSize;

  /// 检测结果流。只允许订阅一次。
  Stream<VisionFrame> get frames => _frames ??= _events
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .map((event) => _parseFrame(event as Map));

  /// 加载模型。
  ///
  /// 返回 `false` 表示**加载失败但 App 可以继续跑**（模型文件缺失、
  /// 输入形状不符等）。调用方应当显示明确原因，而不是白屏。
  ///
  /// ## 为什么由 Dart 读资源再交给原生，而不是原生直接读 APK 内的 assets
  ///
  /// 实测（真机 Redmi / Android 16 / HyperOS）原生 `AssetManager.open()` 读
  /// `flutter_assets/assets/models/detector.tflite` **必然 FileNotFoundException**，
  /// 而同一次运行里 `assets.list()` 递归又能列出这个路径——即 ROM 行为与
  /// Android 文档约定不符。改路径试了三轮都无效，不再与 AssetManager 纠缠。
  ///
  /// Flutter 自己的资源系统是可靠的（`AssetManifest.bin` 里明确列有该 key），
  /// 所以改为：**Dart 用 rootBundle 读出字节 -> 写入应用私有目录 -> 原生读文件**。
  /// 这样彻底绕开 AssetManager 的路径歧义。
  ///
  /// 代价：启动时多一次 10 MB 的写盘。用「已存在且大小一致就跳过」避免重复写。
  Future<bool> loadModel({String? assetKey}) async {
    final key = assetKey ?? defaultModelAssetKey;
    String? filePath;
    try {
      filePath = await _materializeModelToDisk(key);
    } catch (e) {
      _loaded = false;
      _error = '把模型写入应用目录失败：${e.runtimeType}: $e';
      return false;
    }
    return _loadFromPath(filePath);
  }

  /// 把 Flutter 资源落盘到应用私有目录，返回绝对路径。
  ///
  /// 目录来自 `path_provider` 会引入额外依赖（且它会拖入 objective_c，
  /// 见 pubspec 的说明），所以这里直接用原生提供的目录：
  /// 由 [VisionMethods.modelDir] 返回，已保证可写。
  Future<String> _materializeModelToDisk(String assetKey) async {
    final dir = await _method.invokeMethod<String>(VisionMethods.modelDir);
    if (dir == null || dir.isEmpty) {
      throw StateError('原生未返回可写的模型目录');
    }
    final data = await rootBundle.load(assetKey);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

    final target = '$dir/detector.tflite';
    // 已存在且大小一致就跳过写盘：模型是 10 MB，每次启动都写没必要。
    //
    // 注意类型：原生返回的是 kotlin Long，平台通道会映射成 Dart int。
    // 但若在原生侧返回的是 Int 以外的整数类型，泛型写错会**静默得到 null**，
    // 于是每次启动都重写一遍——所以要显式处理 null 并把类型放宽。
    final Object? existingRaw = await _method.invokeMethod<Object?>(
      VisionMethods.fileSize,
      <String, Object>{VisionKeys.path: target},
    );
    final existing = existingRaw is num ? existingRaw.toInt() : -1;
    if (existing == bytes.length) {
      return target;
    }
    await _method.invokeMethod<void>(
      VisionMethods.writeFile,
      <String, Object>{VisionKeys.path: target, VisionKeys.bytes: bytes},
    );
    return target;
  }

  Future<bool> _loadFromPath(String? filePath) async {
    try {
      final reply = await _method.invokeMethod<Map<Object?, Object?>>(
        VisionMethods.loadModel,
        filePath == null ? null : <String, Object>{VisionKeys.model: filePath},
      );
      _loaded = reply?[VisionKeys.loaded] == true;
      _numClasses = _asInt(reply?[VisionKeys.classes]) ?? 0;
      _inputSize = _asInt(reply?[VisionKeys.inputSize]) ?? 0;
      _error = _loaded ? null : (reply?['error'] as String? ?? '未知原因');
      return _loaded;
    } on PlatformException catch (e) {
      _loaded = false;
      _error = '${e.code}: ${e.message}';
      return false;
    } on MissingPluginException {
      // 在 iOS 上尚未实现 VisionPlugin 时会走到这里，这是**预期**的。
      _loaded = false;
      _error = '当前平台尚未实现视觉插件（iOS 待补，见环境文档 §6.4）';
      return false;
    }
  }

  /// 回放/调试用的单帧推理（传原始 Y 平面字节）。
  ///
  /// 实时相机路径不走这里——那条路在原生侧直接把结果推 EventChannel，
  /// 避免每帧搬运整帧字节。
  Future<({List<Detection> detections, double inferenceMs})> detectGray({
    required Uint8List gray,
    required int frameWidth,
    required int frameHeight,
    required int rotationDegrees,
    required double threshold,
  }) async {
    final reply = await _method.invokeMethod<Map<Object?, Object?>>(
      VisionMethods.detect,
      <String, Object>{
        VisionKeys.bytes: gray,
        VisionKeys.frameWidth: frameWidth,
        VisionKeys.frameHeight: frameHeight,
        VisionKeys.rotationDegrees: rotationDegrees,
        VisionKeys.threshold: threshold,
      },
    );
    return (
      detections: _parseDetections(reply?[VisionKeys.detections]),
      inferenceMs: _asDouble(reply?[VisionKeys.inferenceMs]) ?? 0,
    );
  }

  /// 更新原生侧阈值。
  ///
  /// 阈值必须在原生侧生效：低分框若仍跨越通道传过来，每帧白白多一次
  /// 序列化与分配。Dart 侧再过滤一次只是为了让滑动条响应更快。
  Future<void> setThreshold(double value) async {
    try {
      await _method.invokeMethod<void>(
        VisionMethods.setThreshold,
        <String, Object>{VisionKeys.threshold: value},
      );
    } on PlatformException {
      // 原生侧未实现该方法时静默忽略；UI 的滑动条仍按 Dart 侧过滤工作。
    } on MissingPluginException {
      // 同上（iOS 尚未实现时）。
    }
  }

  /// 请求原生侧申请权限并启动相机预览。返回是否真的启动了。
  ///
  /// 权限申请在原生侧完成：Dart 无法自己拿到 Android 的运行时权限，
  /// 而原生若只在插件构造时检查一次权限，用户授权后会一直停在「无权限」，
  /// 相机永不启动——表现为一片黑，且没有任何报错。
  ///
  /// 加超时的原因：权限对话框若因 Activity 重建等原因没有回调，
  /// Future 会永不完成。宁可超时给出明确提示，也不要卡在「正在初始化」。
  Future<bool> startPreview() async {
    try {
      final reply = await _method
          .invokeMethod<Map<Object?, Object?>>(VisionMethods.startPreview)
          .timeout(const Duration(seconds: 60));
      return reply?['started'] == true;
    } on TimeoutException {
      return false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // iOS 尚未实现原生插件时走这里，属预期。
      return false;
    }
  }

  Future<void> release() async {
    try {
      await _method.invokeMethod<void>(VisionMethods.release);
    } on PlatformException {
      // 释放失败不影响退出。
    }
    _loaded = false;
  }

  VisionFrame _parseFrame(Map<Object?, Object?> raw) {
    return VisionFrame(
      detections: _parseDetections(raw[VisionKeys.detections]),
      inferenceMs: _asDouble(raw[VisionKeys.inferenceMs]) ?? 0,
      frameWidth: _asInt(raw[VisionKeys.frameWidth]) ?? 0,
      frameHeight: _asInt(raw[VisionKeys.frameHeight]) ?? 0,
      queueDepth: _asInt(raw['queueDepth']) ?? 0,
    );
  }

  /// 防御式解析：[Detection.fromMap] 对缺键/错类型返回 null 并在此被过滤，
  /// 因此单个坏框不会丢掉整帧结果。
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
}
