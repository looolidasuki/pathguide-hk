import 'package:flutter/services.dart' show rootBundle;

import '../vision/model_manifest.dart';
import '../vision/platform_vision.dart' show defaultModelManifestKey;
import 'api_types.dart';
import 'path_guide_api.dart';

/// 訪客／離線時的實現：**一個網絡請求都不發**。
///
/// 存在的意義：讓「未登入也能完整使用」這條規則有**可測的代碼**，
/// 而不是靠「我們沒調那個接口」這種口頭保證。
class LocalOnlyApi implements PathGuideApi {
  LocalOnlyApi({
    required this.installId,
    this.platform = 'android',
    this.locale = 'zh-HK',
    String? guestToken,
  }) : _guestToken = guestToken ?? 'local-guest-${installId.hashCode}';

  final String installId;
  final String platform;
  final String locale;
  final String _guestToken;

  /// 訪客身分是本機推導的：同一個安裝就是同一個 guestId。
  /// 這讓「沒有網也能當訪客」成立（spec §4.1）。
  @override
  Future<GuestSession> createGuestSession({
    required String installId,
    required String platform,
    required String locale,
  }) async {
    return GuestSession(
      guestId: 'guest-$installId',
      token: _guestToken,
      expiresAt: DateTime.now().add(const Duration(days: 3650)),
    );
  }

  @override
  Future<ModelEnvelope> latestModel() async {
    final parsed =
        parseModelManifest(await rootBundle.loadString(defaultModelManifestKey));
    final m = parsed.manifest;
    if (m == null) {
      // `const`：`ApiFailure` 是 const 建構子，全部參數都是字面量，
      // 不寫 const 會被 `prefer_const_constructors` 記一條 info（門禁是 0 問題）。
      throw const ApiFailure(
          code: 'manifest_bad', message: '端上模型清單無法解析', retryable: false);
    }
    // 清單把 bytes / sha256 宣告成可選（伺服器下發的清單可能還沒有這兩欄），
    // 而 [ModelEnvelope] 兩者都是非空型別。這裡**不補 0 / ''**：那等於假裝
    // 「檔案大小與哈希都對得上」，而下載完整性正是靠這兩欄判斷的。
    final bytes = m.bytes;
    final sha256 = m.sha256;
    if (bytes == null || sha256 == null) {
      throw const ApiFailure(
        code: 'manifest_incomplete',
        message: '端上模型清單缺 bytes 或 sha256',
        retryable: false,
      );
    }
    return ModelEnvelope(
      version: m.version,
      bytes: bytes,
      modelClassCount: m.modelClassCount,
      inputSize: m.inputSize,
      modelClassIds: m.modelClassIds,
      sha256: sha256,
      // `''` 是「沒有下載地址」的哨兵值（離線：模型就在 APK 裡，無處可下），
      // 不是「空字串其實也合法」。
      //
      // ★ 呼叫方必須用 `downloadUrl.isEmpty` 判斷，**不能**用
      //   `Uri.tryParse(downloadUrl) == null`：`Uri.parse('')` 不會失敗，
      //   它回一個「空相對引用」（`path == ''`、`isAbsolute == false`），
      //   於是 `baseUri.resolve('')` 會安靜地解回 base 本身 ——
      //   在 `https://api.example.com/v1/` 上就變成「去抓 API 根路徑」，
      //   不報錯、不下載、也不下載到任何模型。空字串必須當成缺失來擋。
      downloadUrl: '',
    );
  }

  @override
  Future<AuthSession> login(
          {required String method, required String credential}) async =>
      throw ApiNotAvailable('尚未提供登入服務');

  @override
  Future<AuthSession> refresh({required String token}) async =>
      throw ApiNotAvailable('尚未提供登入服務');

  @override
  Future<UploadReceipt> uploadFrame(
          {required String token, required UploadFrameRequest request}) async =>
      throw ApiNotAvailable('上傳需要登入與後端');

  @override
  Future<Map<String, Object?>> fetchSettings({required String token}) async =>
      throw ApiNotAvailable('跨端同步尚未提供');

  @override
  Future<void> saveSettings(
          {required String token, required Map<String, Object?> settings}) async =>
      throw ApiNotAvailable('跨端同步尚未提供');

  @override
  Future<Map<String, Object?>> visionQuery({
    required String token,
    required String imageSha256,
    required String question,
    required String locale,
  }) async =>
      throw ApiNotAvailable('雲端問答尚未提供');

  @override
  Future<Map<String, Object?>> planRoute({
    required String token,
    required String utterance,
    required String locale,
  }) async =>
      throw ApiNotAvailable('路線規劃尚未提供');
}
