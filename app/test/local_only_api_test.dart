// `LocalOnlyApi` 的門禁測試：**這一層有沒有偷偷依賴網絡**。
//
// 只斷言兩件事：
// 1. 訪客身分在離線時也能成立（spec §4.1：沒有網也能當訪客）；
// 2. 需要登入／後端的端點**明確說「尚未提供」**，而不是回假資料。
//
// 第 2 點必須用 `expectLater(...)` 而不是 `expect(api.x(), throwsA(...))`：
// 前者吃的是 Future，後者吃的是「同步拋出」。實作裡凡是該失敗的方法都寫成
// `async => throw`，就是為了讓這裡一定是「Future 完成時失敗」。

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/api/api_types.dart';
import 'package:pathguide/api/local_only_api.dart';

void main() {
  // `latestModel()` 要經 rootBundle 讀端上清單，而 rootBundle 需要 binding
  // （一般 `test()` 不會自動初始化它）。與 platform_mapping_test.dart 同一個做法。
  TestWidgetsFlutterBinding.ensureInitialized();

  final api = LocalOnlyApi(installId: 'install-1');

  test('★ 訪客身分可離線取得，且同一個 installId 拿到同一個 guestId', () async {
    final a = await api.createGuestSession(
        installId: 'install-1', platform: 'android', locale: 'zh-HK');
    final b = await api.createGuestSession(
        installId: 'install-1', platform: 'android', locale: 'zh-HK');
    expect(a.guestId, b.guestId);
    expect(a.token, isNotEmpty);
  });

  test('★ 需要登入的端點一律明確說「尚未提供」，不假裝成功', () async {
    await expectLater(
      api.uploadFrame(
        token: 't',
        request: UploadFrameRequest(
          framePath: '/tmp/a.jpg',
          capturedAt: DateTime.utc(2026, 10, 23),
          modelVersion: 'v',
        ),
      ),
      throwsA(isA<ApiNotAvailable>()),
    );
    await expectLater(api.fetchSettings(token: 't'),
        throwsA(isA<ApiNotAvailable>()));
    await expectLater(
        api.visionQuery(
            token: 't', imageSha256: 'x', question: '有沒有牛河', locale: 'zh-HK'),
        throwsA(isA<ApiNotAvailable>()));
    await expectLater(
        api.planRoute(token: 't', utterance: '去彩明商場', locale: 'zh-HK'),
        throwsA(isA<ApiNotAvailable>()));
    // 以下三條不在 brief 的原始清單裡，補上是為了讓「9 個方法可用/不可用」
    // 兩個方向都被釘住：這份實現不得有任何一條悄悄成功。
    await expectLater(
        api.login(method: 'phone', credential: 'x'),
        throwsA(isA<ApiNotAvailable>()));
    await expectLater(
        api.refresh(token: 't'), throwsA(isA<ApiNotAvailable>()));
    await expectLater(
        api.saveSettings(token: 't', settings: <String, Object?>{}),
        throwsA(isA<ApiNotAvailable>()));
  });

  test('模型清單在離線時取端上清單的版本（不假裝有下載地址）', () async {
    final m = await api.latestModel();
    expect(m.version, isNotEmpty);
    expect(m.downloadUrl, isEmpty, reason: '離線時沒有下載地址，不可編一個出來');
  });
}
