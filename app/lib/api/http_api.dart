import 'dart:convert';

import 'api_types.dart';
import 'http_transport.dart';
import 'path_guide_api.dart';

/// 真 HTTP 實現。端點與請求內容見 spec §7；狀態碼到 [ApiFailure] 的映射
/// **全部集中在 [_send]**，其他方法只管把 JSON 轉成 `api_types.dart` 的模型。
///
/// 令牌從建構子的 `token`／[setToken] 進來，不由各方法自己的 `token` 參數決定：
/// 介面上的 `token` 參數是契約的一部分（`LocalOnlyApi` 用來判「有沒有登入」），
/// 但真正送出的 `Authorization` 標頭只有一份事實源。
class HttpApi implements PathGuideApi {
  HttpApi({required this.baseUrl, required this.transport, String? token})
      // prefer_initializing_formals 建議 `_token` 也改成 `this._token`，但那會把
      // 底線私有名暴露成公開參數標籤（呼叫端要寫 `_token:`），寧可保留顯式賦值。
      // ignore: prefer_initializing_formals
      : _token = token;

  final Uri baseUrl;
  final HttpTransport transport;
  String? _token;

  void setToken(String? token) => _token = token;

  Map<String, String> get _headers {
    final h = <String, String>{'Accept': 'application/json'};
    final t = _token;
    if (t != null && t.isNotEmpty) {
      h['Authorization'] = 'Bearer $t';
    }
    return h;
  }

  /// `resolve` 語義（spec §7 的路徑都是絕對的）：`/v1/...` 會把 base 的路徑
  /// 整個換掉，所以 `https://api.example.test` 上得到
  /// `https://api.example.test/v1/auth/login`。
  Uri _u(String path) => baseUrl.resolve(path);

  /// 送出請求並回傳解碼後的 JSON 物件。
  ///
  /// 狀態碼映射（**唯一**一處，其他方法不得自行判斷）：
  /// - 401 → `auth_expired`，可重試（重登後再試）
  /// - 408 / 429 → `network`，可重試（逾時／被限流都是暫時的）
  /// - ≥ 500 → `server`，不可重試
  /// - 其他 ≥ 400 → `client`，不可重試
  ///
  /// 空 body 當 `{}`：`204 No Content` 是合法的成功回應，不該讓呼叫方去猜。
  Future<Map<String, Object?>> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? fields,
    String? uploadFilePath,
  }) async {
    final res = await transport.send(TransportRequest(
      method: method,
      url: _u(path),
      headers: _headers,
      jsonBody: body == null ? null : utf8.encode(jsonEncode(body)),
      fields: fields,
      uploadFilePath: uploadFilePath,
    ));

    if (res.statusCode == 401) {
      throw const ApiFailure(
          code: 'auth_expired', message: '登入已過期', retryable: true);
    }
    if (res.statusCode == 408 || res.statusCode == 429) {
      throw ApiFailure(
          code: 'network',
          message: '暫時連不上（${res.statusCode}）',
          retryable: true);
    }
    if (res.statusCode >= 500) {
      throw ApiFailure(
          code: 'server',
          message: '伺服器暫時有問題（${res.statusCode}）',
          retryable: false);
    }
    if (res.statusCode >= 400) {
      throw ApiFailure(
          code: 'client',
          message: '請求不被接受（${res.statusCode}）',
          retryable: false);
    }
    if (res.body.trim().isEmpty) {
      return <String, Object?>{};
    }
    final decoded = jsonDecode(res.body);
    return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
  }

  /// 缺欄位一律 `''`，**永不**把 `null` 插值成字串 `'null'`。
  ///
  /// `'${m['x']}'` 在缺欄位時會生出四個字元的 `'null'`，那是一個看起來合法、
  /// 其實有毒的字串：`sha256`／`downloadUrl` 這種欄位一旦變成 `'null'`，
  /// 呼叫方的 `isEmpty` 判斷全部失守（`api_types.dart` 的
  /// `ModelEnvelope.downloadUrl` 就是照這條規矩寫的），下載器會拿 `'null'`
  /// 去拼 URL，而不是乾淨地判定「沒有下載地址」。
  static String _asString(Object? v) => v == null ? '' : '$v';

  static DateTime _asDate(Object? v) {
    final parsed = v is String ? DateTime.tryParse(v) : null;
    return parsed ?? DateTime.now().toUtc();
  }

  @override
  Future<GuestSession> createGuestSession({
    required String installId,
    required String platform,
    required String locale,
  }) async {
    final m = await _send('POST', '/v1/auth/guest', body: <String, Object?>{
      'installId': installId,
      'platform': platform,
      'locale': locale,
    });
    return GuestSession(
      guestId: _asString(m['guestId']),
      token: _asString(m['token']),
      expiresAt: _asDate(m['expiresAt']),
    );
  }

  @override
  Future<AuthSession> login(
      {required String method, required String credential}) async {
    final m = await _send('POST', '/v1/auth/login',
        body: <String, Object?>{'method': method, 'credential': credential});
    return AuthSession(
      userId: _asString(m['userId']),
      token: _asString(m['token']),
      expiresAt: _asDate(m['expiresAt']),
    );
  }

  @override
  Future<AuthSession> refresh({required String token}) async {
    final m = await _send('POST', '/v1/auth/refresh',
        body: <String, Object?>{'token': token});
    return AuthSession(
      userId: _asString(m['userId']),
      token: _asString(m['token']),
      expiresAt: _asDate(m['expiresAt']),
    );
  }

  @override
  Future<UploadReceipt> uploadFrame({
    required String token,
    required UploadFrameRequest request,
  }) async {
    // `capturedAt` 一律 UTC ISO-8601：本地時間帶的是裝置時區，伺服器無從得知
    // 使用者當時在哪個時區，跨時區排隊時會把「幾小時前」算成年月日錯亂。
    final fields = <String, String>{
      'capturedAt': request.capturedAt.toUtc().toIso8601String(),
      'modelVersion': request.modelVersion,
      if (request.routeId != null) 'routeId': request.routeId!,
      if (request.latitude != null) 'lat': '${request.latitude}',
      if (request.longitude != null) 'lng': '${request.longitude}',
    };
    final m = await _send('POST', '/v1/frames',
        fields: fields, uploadFilePath: request.framePath);
    return UploadReceipt(
      frameId: _asString(m['frameId']),
      status: _asString(m['status']),
    );
  }

  @override
  Future<ModelEnvelope> latestModel() async {
    final m = await _send('GET', '/v1/models/latest');
    return ModelEnvelope(
      version: _asString(m['version']),
      bytes: (m['bytes'] as num?)?.toInt() ?? 0,
      modelClassCount: (m['modelClassCount'] as num?)?.toInt() ?? 0,
      inputSize: (m['inputSize'] as num?)?.toInt() ?? 0,
      modelClassIds: <int>[
        for (final id in (m['modelClassIds'] as List? ?? const <Object?>[]))
          (id as num).toInt(),
      ],
      sha256: _asString(m['sha256']),
      // 伺服器沒給下載地址 → `''`（`ModelEnvelope.downloadUrl` 的哨兵值），
      // 不是 `'null'`，也不是任何其他「看起來有值」的字串。
      downloadUrl: _asString(m['downloadUrl']),
    );
  }

  @override
  Future<Map<String, Object?>> fetchSettings({required String token}) =>
      _send('GET', '/v1/settings');

  @override
  Future<void> saveSettings({
    required String token,
    required Map<String, Object?> settings,
  }) async {
    await _send('PUT', '/v1/settings',
        body: <String, Object?>{'settings': settings});
  }

  @override
  Future<Map<String, Object?>> visionQuery({
    required String token,
    required String imageSha256,
    required String question,
    required String locale,
  }) =>
      // Spec 4 尚未實作：打到真實端點，但契約已定（spec §7）。
      _send('POST', '/v1/vision/query', body: <String, Object?>{
        'imageSha256': imageSha256,
        'question': question,
        'locale': locale,
      });

  @override
  Future<Map<String, Object?>> planRoute({
    required String token,
    required String utterance,
    required String locale,
  }) =>
      _send('POST', '/v1/plan',
          body: <String, Object?>{'utterance': utterance, 'locale': locale});
}
