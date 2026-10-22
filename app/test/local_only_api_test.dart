// `LocalOnlyApi` 的門禁測試：**這一層有沒有偷偷依賴網絡**。
//
// 斷言三件事：
// 1. 訪客身分在離線時也能成立（spec §4.1：沒有網也能當訪客）；
// 2. 需要登入／後端的端點**明確說「尚未提供」**，而不是回假資料；
// 3. 「不發任何請求」本身被**釘住**：整套測試期間 `HttpOverrides.global` 是一個
//    「一被要求建立 HttpClient 就拋錯」的 override，任何一次偷偷上網都會讓測試
//    失敗，而不是靠「我們看過 import 清單」這種人眼保證。
//
// 第 2 點必須用 `expectLater(...)` 而不是 `expect(api.x(), throwsA(...))`：
// 前者吃的是 Future，後者吃的是「同步拋出」。實作裡凡是該失敗的方法都寫成
// `async => throw`，就是為了讓這裡一定是「Future 完成時失敗」。

import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/api/api_types.dart';
import 'package:pathguide/api/local_only_api.dart';

/// 有人想上網時拋的錯誤。**型別本身就是證據**：它出現在失敗輸出裡，
/// 一眼就看出是「有代碼建立了 HttpClient」，而不是別的原因炸掉。
class OfflineNetworkForbidden implements Exception {
  const OfflineNetworkForbidden();

  @override
  String toString() => 'OfflineNetworkForbidden: 這個測試不許建立 HttpClient —— '
      '訪客／離線路徑必須完全不發請求';
}

/// 一被要求建立 [HttpClient] 就拋 [OfflineNetworkForbidden]。
///
/// `HttpClient(...)` 建構子走的是 `HttpOverrides.current.createHttpClient`，
/// 所以這一層能攔住任何想上網的 `dart:io` 高階 API —— 包括 `HttpClient` 直接
/// new 出來、`HttpClient.getUrl`、`HttpClient.post` 這些最可能被偷用的入口。
class NoNetworkHttpOverrides extends HttpOverrides {
  /// 總共被要求建立幾次 client。
  ///
  /// 光靠「拋錯」還不夠：假如將來的代碼把這個錯誤 `catch` 掉再吞下去，測試照樣
  /// 會綠。所以每次攔截都留下計數，測試尾端斷言它為 0，才真的證明「一個請求都
  /// 沒發」。
  int attempts = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw const OfflineNetworkForbidden();
  }
}

void main() {
  // `latestModel()` 要經 rootBundle 讀端上清單，而 rootBundle 需要 binding
  // （一般 `test()` 不會自動初始化它）。與 platform_mapping_test.dart 同一個做法。
  TestWidgetsFlutterBinding.ensureInitialized();

  // binding 在 `initInstances` 時會把 `HttpOverrides.global` 換成 flutter_test
  // 自己的 mock（一律回 400）；這裡在**每個測試之前**蓋上「一建 client 就拋」的
  // 版本，測完把原值放回去，免得影響同一 isolate 內其他測試。
  //
  // ★ 擋網不會擋到讀清單：`rootBundle` 讀資產走的是檔案／buffer 通道，
  //   不經 `HttpClient`，所以下面那條真正跑 `latestModel()` 的測試照樣能過。
  late NoNetworkHttpOverrides networkGuard;
  HttpOverrides? previousOverrides;

  setUp(() {
    previousOverrides = HttpOverrides.current;
    networkGuard = NoNetworkHttpOverrides();
    HttpOverrides.global = networkGuard;
  });

  tearDown(() {
    HttpOverrides.global = previousOverrides;
    previousOverrides = null;
  });

  // 一份「合法但沒有 bytes / sha256」的端上清單：其餘欄位都照
  // `assets/models/detector.json` 的規矩填，好讓失敗原因只可能是缺這兩欄，
  // 而不是被解析器別的規則先擋掉（id 6/11/7 都在類別表內）。
  const incompleteManifest = '{"format":1,"version":"2026-10-02.test",'
      '"file":"detector.tflite","inputSize":416,"modelClassCount":3,'
      '"modelClassIds":[6,11,7]}';

  final api = LocalOnlyApi(installId: 'install-1');

  test('★ 網絡禁令本身有效（否則這份測試的綠色都是假的）', () {
    expect(() => HttpClient(), throwsA(isA<OfflineNetworkForbidden>()));
    expect(networkGuard.attempts, 1, reason: '攔截器沒生效，後面的測試就證明不了任何事');
  });

  test('★ 訪客路徑在完全禁止網絡的情況下仍然可用', () async {
    // 同一個測試裡把「離線可用的兩條路徑」都跑一遍：任何一次 `HttpClient()`
    // 都會立刻拋 `OfflineNetworkForbidden`，而尾端斷言 `attempts == 0`
    // 連「偷偷建了又被 catch 掉」也一起擋下。
    final offline = LocalOnlyApi(installId: 'install-offline');
    final guest = await offline.createGuestSession(
        installId: 'install-offline', platform: 'android', locale: 'zh-HK');
    expect(guest.guestId, isNotEmpty);
    expect(guest.token, isNotEmpty);

    final model = await offline.latestModel();
    expect(model.version, isNotEmpty);
    expect(model.downloadUrl, isEmpty);

    expect(networkGuard.attempts, 0,
        reason: '訪客／離線路徑一個 HttpClient 都不該建立（更不用說發請求）');
  });

  test('★ 訪客身分可離線取得，且同一個 installId 拿到同一個 guestId', () async {
    final a = await api.createGuestSession(
        installId: 'install-1', platform: 'android', locale: 'zh-HK');
    final b = await api.createGuestSession(
        installId: 'install-1', platform: 'android', locale: 'zh-HK');
    expect(a.guestId, b.guestId);
    expect(a.token, isNotEmpty);
    expect(networkGuard.attempts, 0);
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
    expect(networkGuard.attempts, 0,
        reason: '連「試一下再失敗」都不行：這些端點必須是本地直接拋');
  });

  test('模型清單在離線時取端上清單的版本（不假裝有下載地址）', () async {
    final m = await api.latestModel();
    expect(m.version, isNotEmpty);
    expect(m.downloadUrl, isEmpty, reason: '離線時沒有下載地址，不可編一個出來');
    expect(networkGuard.attempts, 0);
  });

  test('★ 端上清單缺 bytes/sha256 時拋 manifest_incomplete，且不可重試', () async {
    // 這條錯誤路徑（Task 5 遺留的 deviation）沒有 `manifestLoader` 這道縫
    // 就只能靠生產環境踩到：清單缺兩欄時**不可以**補 0／''，必須明確失敗。
    final seam = LocalOnlyApi(
      installId: 'install-1',
      manifestLoader: () async => incompleteManifest,
    );
    await expectLater(
      seam.latestModel(),
      throwsA(
        isA<ApiFailure>()
            .having((f) => f.code, 'code', 'manifest_incomplete')
            .having((f) => f.retryable, 'retryable', false),
      ),
    );
  });

  test('★ 清單資源讀不到時包成 ApiFailure(manifest_bad)，on ApiFailure 不會漏接', () async {
    // `rootBundle.loadString` 讀不到資源時拋的是 FlutterError；若不包成
    // ApiFailure，只寫 `on ApiFailure` 的呼叫方就漏接這條路徑（降級失效）。
    final seam = LocalOnlyApi(
      installId: 'install-1',
      manifestLoader: () async =>
          throw FlutterError('assets/models/detector.json 不在 assets 裡'),
    );
    await expectLater(
      seam.latestModel(),
      throwsA(isA<ApiFailure>()
          .having((f) => f.code, 'code', 'manifest_bad')
          .having((f) => f.retryable, 'retryable', false)
          .having(
              (f) => f.message, 'message', contains('端上模型清單讀不到'))),
    );
  });
}
