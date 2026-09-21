import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'platform_contract.dart';

/// 相机预览的平台视图。
///
/// 预览由**原生侧**渲染（Android：CameraX 的 `PreviewView`），嵌进 Flutter
/// 控件树。这样相机只被一个栈占用，不会出现「相机插件 + 原生分析」两套栈
/// 抢设备的问题。也正因为预览在原生侧，检测框的**屏幕坐标必须由 Dart 侧算**
/// （见 `mapDetectionsToScreen`），原生只回传归一化坐标。
///
/// iOS 侧对应 `UiKitView`，`viewType` 用同一个常量 [kVisionPreviewViewType]
/// ——不一致时表现为**一块空白**，两端都不报错。
class VisionPreview extends StatelessWidget {
  const VisionPreview({super.key});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const ColoredBox(color: Color(0xFF101418));
    if (Platform.isAndroid) {
      return AndroidView(
        viewType: kVisionPreviewViewType,
        creationParams: const <String, Object?>{},
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    if (Platform.isIOS) {
      return const UiKitView(
        viewType: kVisionPreviewViewType,
        creationParams: <String, Object?>{},
        creationParamsCodec: StandardMessageCodec(),
      );
    }
    // 桌面：没有原生预览，由调用方叠加占位内容。
    return const ColoredBox(color: Color(0xFF101418));
  }
}
