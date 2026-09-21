import 'dart:async';

import 'package:flutter/services.dart';

import 'detection.dart';
import 'platform_contract.dart';
import 'vision_source.dart';

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
  Future<bool> loadModel({String? path}) async {
    try {
      final reply = await _method.invokeMethod<Map<Object?, Object?>>(
        VisionMethods.loadModel,
        path == null ? null : <String, Object>{VisionKeys.model: path},
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
