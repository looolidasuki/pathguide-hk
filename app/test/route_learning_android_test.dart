// 本機路標候選（學習庫）在 Android 開放：以真實主機作業系統判斷，
// 主機測試的 defaultTargetPlatform 不會誤開。
// Android 的儲存位置（App 私有目錄，不經 route_storage 通道）由真機驗證。

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/route_learning_store.dart';
import 'package:pathguide/route_memory/route_platform_profile.dart';

void main() {
  tearDown(() {
    RoutePlatform.debugAndroid = null;
    debugDefaultTargetPlatformOverride = null;
  });

  test('the learning store is offered on Android', () {
    RoutePlatform.debugAndroid = true;
    expect(RouteLearningStore.platformOpener, isNotNull);
  });

  test('the learning store stays on iOS', () {
    RoutePlatform.debugAndroid = false;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(RouteLearningStore.platformOpener, isNotNull);
  });

  test('a host test targeting android does not open a learning store', () {
    RoutePlatform.debugAndroid = false;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(RouteLearningStore.platformOpener, isNull);
  });
}
