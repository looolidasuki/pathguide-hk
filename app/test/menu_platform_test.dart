// 菜單（餐牌）功能的**平台支援契約**。
//
// 為什麼要有這條：`menu_reader.dart` 的 `supported` 決定整個功能入口出不出的來。
// 2026-10-23 之前它寫死 `== TargetPlatform.iOS`，Android 使用者連入口都看不到；
// 那次補上 `MenuPlugin.kt` 之後，如果哪天有人把這個判斷改回去，功能會**靜默消失**
// （不報錯、不崩、只是按鈕不見了），所以用測試釘住。

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/menu/menu_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('★ Android 有原生菜單實作（MenuPlugin.kt，ML Kit 中文辨識）', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final reader = NativeMenuReader();
    expect(
      reader.supported,
      isTrue,
      reason: 'Android 缺這個實作時，菜單入口會靜默消失，而不是報錯',
    );
    reader.dispose();
  });

  test('★ iOS 仍然支援（上游原有實作）', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final reader = NativeMenuReader();
    expect(reader.supported, isTrue);
    reader.dispose();
  });

  test('★ 桌面平台不支援，而且錯誤訊息說得出目前支援哪些平台', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final reader = NativeMenuReader();
    expect(reader.supported, isFalse);

    await expectLater(
      reader.read(MenuImageSource.camera, onRecognizing: () {}),
      throwsA(
        isA<MenuFailure>()
            .having((f) => f.message, 'message', contains('Android'))
            .having((f) => f.message, 'message', contains('iPhone')),
      ),
      reason: '使用者要知道自己是不是用錯平台，而不是看到一句「失敗」',
    );
    reader.dispose();
  });
}
