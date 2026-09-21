import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'platform_contract.dart';

/// 相机预览的平台视图。
///
/// 预览由**原生侧**（Android: CameraX 的 `PreviewView`）渲染，通过
/// `AndroidView`/`UiKitView` 嵌进 Flutter 控件树。这样相机只被一个栈占用，
/// 不会出现「Flutter 相机插件 + 原生分析」两套栈抢设备的问题。
///
/// iOS 侧对应实现为 `UiKitView`，`viewType` 用同一个常量
/// （[kVisionPreviewViewType]，定义在契约文件里）。
class VisionPreview extends StatelessWidget {
  const VisionPreview({super.key});

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb && Platform.isAndroid) {
      return PlatformViewLink(
        viewType: kVisionPreviewViewType,
        surfaceFactory: (context, controller) {
          return AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
            hitTestBehavior: PlatformViewHitTestBehavior.transparent,
          );
        },
        onCreatePlatformView: (params) {
          return PlatformViewsService.initSurfaceAndroidView(
            id: params.id,
            viewType: kVisionPreviewViewType,
            layoutDirection: TextDirection.ltr,
            creationParams: const <String, Object?>{},
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () => params.onFocusChanged(true),
          )
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..create();
        },
      );
    }
    if (!kIsWeb && Platform.isIOS) {
      return const UiKitView(
        viewType: kVisionPreviewViewType,
        creationParams: <String, Object?>{},
        creationParamsCodec: StandardMessageCodec(),
      );
    }
    // 桌面/网页：没有原生预览，由调用方叠加占位内容。
    return const ColoredBox(color: Color(0xFF101418));
  }
}
