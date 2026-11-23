// 路標錄音備註在 Android 開放（原生 RouteNoteAudioPlugin.kt），
// 以真實主機作業系統判斷，主機測試的 defaultTargetPlatform 不會誤開。

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/route_audio_note_dialog.dart';
import 'package:pathguide/route_memory/route_platform_profile.dart';

void main() {
  tearDown(() {
    RoutePlatform.debugAndroid = null;
    debugDefaultTargetPlatformOverride = null;
  });

  test('audio notes are offered on Android', () {
    RoutePlatform.debugAndroid = true;
    expect(RouteNoteAudio.supported, isTrue);
  });

  test('audio notes stay on iOS', () {
    RoutePlatform.debugAndroid = false;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(RouteNoteAudio.supported, isTrue);
  });

  test('a host test targeting android does not turn audio notes on', () {
    RoutePlatform.debugAndroid = false;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(RouteNoteAudio.supported, isFalse);
  });
}
