import 'dart:convert';

import 'api_types.dart';
import 'http_transport.dart';
import 'path_guide_api.dart';

/// 真 HTTP 實現。端點與請求內容見 spec §7；狀態碼到 [ApiFailure] 的映射
/// **全部集中在 [_send]**，其他方法只管把 JSON 轉成 `api_types.dart` 的模型。
///
/// **公開方法只會拋 [ApiFailure]**：狀態碼、連線失敗、逾時、body 不是 JSON、
/// 欄位型別不對、要送出的 body 序列化不了，全部在這一層收斂完成。呼叫方寫
/// `on ApiFailure` 就接得到，不必認識 `dart:io`／`dart:convert` 的例外型別 ——
/// 走路中的使用者沒有第二次機會發現「安靜地什麼都沒說」。
///
/// 令牌有兩個來源：[setToken]（或建構子）存的那一份，與各方法自己的 `token`
/// 參數；兩者並存且**參數優先**，見 [_headersFor]。
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

  /// 這次請求要帶的標頭。
  ///
  /// `Authorization` 的規則是「**該次呼叫的 `token` 非空就用它**，否則回落到
  /// [setToken] 存的那一份」。為什麼不能只認一份：
  /// - 只認 `setToken` → 呼叫端若照介面簽章每呼叫傳 token（Task 8／9 很自然
  ///   會這樣做），那些參數會被靜默丟掉，請求帶著過期或空的令牌出去 → 401 →
  ///   `auth_expired`（可重試）→ 佇列無限重試，而且每次都重送同一份過期令牌。
  /// - 只認參數 → `setToken` 這個既有公開 API 失效，登入一次之後不想每個方法
  ///   都再傳一次的呼叫端會全部掉驗證。
  ///
  /// 空字串一律當成「這次沒有指定」，不是「這次不要帶」：介面用的是
  /// `required String token`，呼叫端沒有 `null` 可以用來表示「不帶」；
  /// 真的不要帶就把 [setToken] 設成 `null`。
  Map<String, String> _headersFor(String? token) {
    final h = <String, String>{'Accept': 'application/json'};
    final effective = (token != null && token.isNotEmpty) ? token : _token;
    if (effective != null && effective.isNotEmpty) {
      h['Authorization'] = 'Bearer $effective';
    }
    return h;
  }

  /// `resolve` 語義（spec §7 的路徑都是絕對的）：`/v1/...` 會把 base 的路徑
  /// 整個換掉，所以 `https://api.example.test` 上得到
  /// `https://api.example.test/v1/auth/login`。
  Uri _u(String path) => baseUrl.resolve(path);

  /// 伺服器回了 2xx，但 body 不是契約要的 JSON 物件。
  ///
  /// 現實中的觸發者不是「伺服器寫壞了」，而是**走著走著連上了一個擋在中間的
  /// 網頁**：商場／電信商的 Wi-Fi 登入頁、代理回的 HTML 錯誤頁、被截斷的 body。
  /// 這種回應重試沒有意義（下一次還是同一頁），所以不可重試；訊息是唸給人聽的
  /// **一句話**（Global Constraints：錯誤不彈窗，寫狀態檔 + 一句可聽說明）。
  static ApiFailure _badResponse() => const ApiFailure(
        code: 'bad_response',
        message: '伺服器回應格式不對，請改用離線功能',
        retryable: false,
      );

  /// 送出請求並回傳解碼後的 JSON 物件。
  ///
  /// [token] 是該次呼叫的令牌；非空時優先於 [setToken] 存的值（見 [_headersFor]）。
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
    String? token,
    Map<String, Object?>? body,
    Map<String, String>? fields,
    String? uploadFilePath,
  }) async {
    final TransportResponse res;
    try {
      res = await transport.send(TransportRequest(
        method: method,
        url: _u(path),
        headers: _headersFor(token),
        jsonBody: body == null ? null : utf8.encode(jsonEncode(body)),
        fields: fields,
        uploadFilePath: uploadFilePath,
      ));
    } on ApiFailure {
      // 傳輸層已經分好類（`missing_file`／逾時 `network`），原樣往上丟。
      rethrow;
    } on JsonUnsupportedObjectError {
      // 呼叫方把不能序列化的東西（`DateTime`、`Duration`、自訂物件）放進 body。
      // 這是 `Error` 不是 `Exception`，原本會直接穿過呼叫方的 `on ApiFailure`；
      // 它同樣不是網路問題（重試沒用），但**更不能安靜**。
      throw const ApiFailure(
        code: 'client',
        message: '這次要送出的內容無法送出',
        retryable: false,
      );
    } on Exception {
      // 傳輸層其他失敗（`SocketException` 連不上、`HttpException` 中途斷線）
      // 也收斂成契約型別：呼叫方寫 `on ApiFailure` 就接得到，不必認識 `dart:io`。
      throw const ApiFailure(
        code: 'network',
        message: '連線不穩，請稍後再試',
        retryable: true,
      );
    }

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
    final Object? decoded;
    try {
      decoded = jsonDecode(res.body);
    } on FormatException {
      throw _badResponse();
    }
    if (decoded is Map<String, Object?>) {
      return decoded;
    }
    // 合法 JSON 但不是物件（`[]`、`"ok"`、`null`）：一樣不是契約的形狀。
    // 這裡**不**安靜回 `{}`：回空物件會讓 `login` 拿到空 token、`latestModel`
    // 拿到空版本，呼叫方要到下一次請求才以 401 發現，錯誤現場離原因太遠。
    throw _badResponse();
  }

  /// 缺欄位一律 `''`，**永不**把 `null` 插值成字串 `'null'`。
  ///
  /// `'${m['x']}'` 在缺欄位時會生出四個字元的 `'null'`，那是一個看起來合法、
  /// 其實有毒的字串：`sha256`／`downloadUrl` 這種欄位一旦變成 `'null'`，
  /// 呼叫方的 `isEmpty` 判斷全部失守（`api_types.dart` 的
  /// `ModelEnvelope.downloadUrl` 就是照這條規矩寫的），下載器會拿 `'null'`
  /// 去拼 URL，而不是乾淨地判定「沒有下載地址」。
  static String _asString(Object? v) => v == null ? '' : '$v';

  /// 數值欄位轉 `int`（缺欄位／`null` 是合法的 0）。
  ///
  /// 型別不對（`"42"`、`true`、物件）→ [ApiFailure] `bad_response`，
  /// **不讓 `TypeError`／`CastError` 漏出去**：`m['bytes'] as num?` 在值是字串時
  /// 拋的是 `TypeError`，呼叫方的 `on ApiFailure` 接不到，等於沒有任何說明。
  static int _asInt(Object? v) {
    if (v == null) {
      return 0;
    }
    if (v is num) {
      return v.toInt();
    }
    throw _badResponse();
  }

  /// 整數陣列（`modelClassIds`）：缺欄位 → 空陣列；**任何一個元素不是數字**
  /// → `bad_response`，不是「跳過那一個」也不是漏出 `TypeError`。
  ///
  /// 跳過會讓呼叫方拿到一份「看起來正常、其實少了一類」的清單，那種錯比
  /// 明確失敗難查得多。
  static List<int> _asIntList(Object? v) {
    if (v == null) {
      return const <int>[];
    }
    if (v is! List) {
      throw _badResponse();
    }
    final ids = <int>[];
    for (final id in v) {
      if (id is! num) {
        throw _badResponse();
      }
      ids.add(id.toInt());
    }
    return ids;
  }

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

  /// `{token}` 走 body（spec §7 第 3 條），**同時**當作這次請求的令牌。
  ///
  /// 不傳給 [_send] 的話，送出的 `Authorization` 會是 [setToken] 存的舊值 ——
  /// 要換新的那個通常已經過期，拿著它去換只會被回 401 `auth_expired`，
  /// 於是「更新令牌」變成「無限重試同一份過期令牌」。
  @override
  Future<AuthSession> refresh({required String token}) async {
    final m = await _send('POST', '/v1/auth/refresh',
        token: token, body: <String, Object?>{'token': token});
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
        token: token, fields: fields, uploadFilePath: request.framePath);
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
      bytes: _asInt(m['bytes']),
      modelClassCount: _asInt(m['modelClassCount']),
      inputSize: _asInt(m['inputSize']),
      modelClassIds: _asIntList(m['modelClassIds']),
      sha256: _asString(m['sha256']),
      // 伺服器沒給下載地址 → `''`（`ModelEnvelope.downloadUrl` 的哨兵值），
      // 不是 `'null'`，也不是任何其他「看起來有值」的字串。
      downloadUrl: _asString(m['downloadUrl']),
    );
  }

  @override
  Future<Map<String, Object?>> fetchSettings({required String token}) =>
      _send('GET', '/v1/settings', token: token);

  @override
  Future<void> saveSettings({
    required String token,
    required Map<String, Object?> settings,
  }) async {
    await _send('PUT', '/v1/settings',
        token: token, body: <String, Object?>{'settings': settings});
  }

  @override
  Future<Map<String, Object?>> visionQuery({
    required String token,
    required String imageSha256,
    required String question,
    required String locale,
  }) =>
      // Spec 4 尚未實作：打到真實端點，但契約已定（spec §7）。
      _send('POST', '/v1/vision/query', token: token, body: <String, Object?>{
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
      _send('POST', '/v1/plan', token: token,
          body: <String, Object?>{'utterance': utterance, 'locale': locale});
}
