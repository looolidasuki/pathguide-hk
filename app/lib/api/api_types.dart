/// API 的資料模型。**這裡是唯一事實源**：欄位名與 spec §4 一致。
///
/// 為什麼不用 JSON 直接滿天飛：契約一旦漂移不會報錯，只會安靜地少一個欄位。
class GuestSession {
  const GuestSession({
    required this.guestId,
    required this.token,
    required this.expiresAt,
  });

  final String guestId;
  final String token;
  final DateTime expiresAt;
}

class AuthSession {
  const AuthSession({
    required this.userId,
    required this.token,
    required this.expiresAt,
  });

  final String userId;
  final String token;
  final DateTime expiresAt;
}

/// 一幀要上傳的素材（錄製路線或未識別障礙物）。
class UploadFrameRequest {
  const UploadFrameRequest({
    required this.framePath,
    required this.capturedAt,
    required this.modelVersion,
    this.routeId,
    this.latitude,
    this.longitude,
  });

  final String framePath;
  final DateTime capturedAt;
  final String modelVersion;
  final String? routeId;

  /// 室內錄製沒有定位；兩個都為 null 表示「無 GPS」。
  final double? latitude;
  final double? longitude;
}

/// 上傳回執。`status` 用 spec §6 的狀態機字串。
class UploadReceipt {
  const UploadReceipt({required this.frameId, required this.status});

  final String frameId;
  final String status;
}

/// 模型清單（與 `assets/models/detector.json` 同 schema，另加下載資訊）。
class ModelEnvelope {
  const ModelEnvelope({
    required this.version,
    required this.bytes,
    required this.modelClassCount,
    required this.inputSize,
    required this.modelClassIds,
    required this.sha256,
    required this.downloadUrl,
  });

  final String version;
  final int bytes;
  final int modelClassCount;
  final int inputSize;
  final List<int> modelClassIds;
  final String sha256;

  /// 模型下載地址。**空字串 `''` 是「沒有下載可用」的哨兵值**（離線／內建模型：
  /// 模型就在 APK 裡，無處可下），不是「空字串其實也合法」。伺服器下發的清單
  /// 一律給真地址；只有離線／端上來源才給 `''`。
  ///
  /// ★ 呼叫方**必須先 `isEmpty` 判斷**，不可以直接把它丟給 `Uri.parse`／
  ///   `baseUri.resolve`：`Uri.parse('')` 不會失敗，它回一個空相對引用
  ///   （`path == ''`、`isAbsolute == false`），於是 `base.resolve('')` 會安靜
  ///   解回 base 本身 —— 在 `https://api.example.com/v1/` 上就變成「去抓 API 根
  ///   路徑」，不報錯、也不下載到任何模型；`Uri.tryParse('') == null` 同樣判斷
  ///   不出缺失。空字串必須當成「沒有下載」來擋。
  final String downloadUrl;
}

class ApiFailure implements Exception {
  const ApiFailure({
    required this.code,
    required this.message,
    required this.retryable,
  });

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => 'ApiFailure($code): $message';
}

/// Spec 4/5 的端點在 Spec 1 尚未實作。**明確報「尚未提供」而不是假裝成功**。
class ApiNotAvailable extends ApiFailure {
  ApiNotAvailable([String message = '此功能尚未提供'])
      : super(code: 'not_available', message: message, retryable: false);
}
