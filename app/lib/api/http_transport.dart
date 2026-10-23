import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_types.dart';

/// 一次 HTTP 請求的描述。
///
/// 刻意**不用** `dio`／`http`：本倉庫路徑含空格，任何新依賴都要先證明能構建
/// （spec §1.3），而本層需要的只有「JSON body」與「文字欄位 + 一個檔案」兩種情況，
/// 用 `dart:io` 手寫比引入一個套件便宜。
class TransportRequest {
  const TransportRequest({
    required this.method,
    required this.url,
    this.headers = const <String, String>{},
    this.jsonBody,
    this.fields,
    this.uploadFilePath,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;

  /// 已編碼的 JSON body。`null` 表示沒有 body（GET／DELETE）。
  final List<int>? jsonBody;

  /// multipart 的文字欄位（`capturedAt`／`modelVersion`／`routeId` 等）。
  final Map<String, String>? fields;

  /// multipart 的檔案欄位（一幀 JPEG）。非 `null` 時走 multipart 而不是 JSON。
  final String? uploadFilePath;
}

class TransportResponse {
  const TransportResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// HTTP 傳輸的抽象。
///
/// 存在的意義：測試**一律不碰真網**（Global Constraints），`HttpApi` 的狀態碼映射
/// 與請求組裝因此可以在 `FakeTransport` 上釘死，不必起本機伺服器。
abstract interface class HttpTransport {
  Future<TransportResponse> send(TransportRequest request);
}

/// 為整個請求加上時限；逾時換成**可重試**的 [ApiFailure]（`network`）。
///
/// 獨立成頂層函式（而不是寫死在 [HttpClientTransport.send] 裡）是為了可測：
/// 傳一個永不完成的 Future 進來，就能在不碰真網的前提下釘住「逾時 → 可重試」
/// 這條轉換。
///
/// 逾時**不會**取消底層連線：`dart:io` 沒有取消句柄，本層又不准加依賴。
/// 被放棄的請求最終會自己失敗，那時它的錯誤由 `.timeout` 的 handler 吃掉，
/// 不會變成未處理的 zone 錯誤；代價只是那條連線會多佔到它自己逾時為止。
Future<TransportResponse> withRequestTimeout(
  Future<TransportResponse> Function() work, {
  Duration timeout = HttpClientTransport.requestTimeout,
}) async {
  try {
    return await work().timeout(timeout);
  } on TimeoutException {
    throw const ApiFailure(
      code: 'network',
      message: '連線太久沒有回應，請稍後再試',
      retryable: true,
    );
  }
}

/// 讀一幀要上傳的 JPEG。
///
/// 讀不到（系統清掉快取、使用者刪了相簿、路徑寫錯）時**不得**讓
/// `PathNotFoundException`（`FileSystemException`）漏出去：它對呼叫方不是
/// [ApiFailure]，「可重試 or 放棄」無從判斷，Task 9 的上傳隊列會卡在一筆
/// 永遠處理不了的檔案上、還說不出原因。所以這裡換成 `missing_file`／不可重試。
Future<List<int>> readUploadFile(String path) async {
  try {
    return await File(path).readAsBytes();
  } on FileSystemException {
    throw const ApiFailure(
      code: 'missing_file',
      message: '找不到要上傳的檔案，這一筆無法送出',
      retryable: false,
    );
  }
}

/// 依 [boundary] 組出 multipart/form-data 的完整位元組。
///
/// **純函式**：不碰檔案系統、不碰網路，於是框線可以逐位元組斷言，
/// 不必起本機伺服器（Global Constraints：測試一律不碰真網）。手寫框線的風險
/// 全在「少一個 `\r\n`」這種地方，而那種錯只會在真的連上後端時才被發現。
///
/// 版面（每個文字欄位一段，最後是檔案段與收尾）：
/// ```
/// --B\r\n
/// Content-Disposition: form-data; name="<key>"\r\n
/// \r\n
/// <value>\r\n
/// ...
/// --B\r\n
/// Content-Disposition: form-data; name="frame"; filename="<name>"\r\n
/// Content-Type: image/jpeg\r\n
/// \r\n
/// <原樣檔案位元組>
/// \r\n--B--\r\n
/// ```
List<int> buildMultipartBody({
  required String boundary,
  required Map<String, String> fields,
  required String filename,
  required List<int> fileBytes,
}) {
  // 用 `for` 而不是 `forEach(函數字面量)`：`avoid_function_literals_in_foreach_calls`
  // 在 `package:lints` 的 core 裡（`flutter_lints` 間接引入），門禁是 0 問題。
  final head = StringBuffer();
  for (final entry in fields.entries) {
    head.write('--$boundary\r\n');
    head.write('Content-Disposition: form-data; name="${entry.key}"\r\n\r\n');
    head.write('${entry.value}\r\n');
  }
  head.write('--$boundary\r\n');
  head.write('Content-Disposition: form-data; name="frame"; '
      'filename="$filename"\r\n');
  head.write('Content-Type: image/jpeg\r\n\r\n');

  // 用 `<int>[]` 而不是 `BytesBuilder`：後者在 `dart:io` 的重新導出已被標
  // `@Deprecated`（會讓 `flutter analyze` 多一條 info），而它的新家
  // `dart:typed_data` 不在本任務允許的 import 清單（`dart:io`／`dart:convert`／
  // `dart:async`）裡。一幀 JPEG 只有數十 KB，這裡的複製可以接受。
  final body = <int>[];
  body.addAll(utf8.encode(head.toString()));
  // 檔案位元組**原樣**接在 head 之後：不編碼、不轉義。
  body.addAll(fileBytes);
  body.addAll(utf8.encode('\r\n--$boundary--\r\n'));
  return body;
}

/// 真正的 HTTP 實現（`dart:io` `HttpClient`）。
///
/// multipart 手寫而不是靠套件：邊界字串用固定前綴＋時間戳，內容只有
/// 「文字欄位 + 一個二進位檔」這種最簡情況，不值得為它加依賴。
class HttpClientTransport implements HttpTransport {
  HttpClientTransport({HttpClient? client}) : _client = _defaultClient(client);

  /// 整段請求的時限（連線 + 送出 + 讀完回應）。
  ///
  /// **只有 `connectionTimeout` 不夠**：它管的是「TCP 連線多久建不起來」。
  /// 伺服器一旦**接受**連線卻不再回一個位元組（後端卡死、行動網路半斷、
  /// 中間設備把連線吃進黑洞），`req.close()` 與讀 body 會永遠 pending ——
  /// 那既不是成功也不是 [ApiFailure]，呼叫方只能一直等，既不能重試也不能放棄。
  /// 訪客／離線路徑不可以被這種狀態拖住（Global Constraints：任何 API 失敗都
  /// 不得阻塞啟動），所以外層再加一道總時限，逾時一律換成可重試的 `network`。
  static const Duration requestTimeout = Duration(seconds: 30);

  /// 預設 10 秒連線逾時：訪客／離線路徑不應該被一個連不上的後端拖住啟動
  /// （Global Constraints：任何 API 失敗都不得阻塞啟動）。
  /// 外部注入的 `client` 原樣使用，不動它的設定。
  static HttpClient _defaultClient(HttpClient? client) =>
      client ??
      (HttpClient()..connectionTimeout = const Duration(seconds: 10));

  final HttpClient _client;

  @override
  Future<TransportResponse> send(TransportRequest request) =>
      withRequestTimeout(() => _send(request));

  Future<TransportResponse> _send(TransportRequest request) async {
    // 先讀檔案、再開連線：檔案不見時連線都還沒建，不會留下一個開著卻沒用到的
    // 請求（`dart:io` 的 `HttpClientRequest` 沒有關閉語義，只有 `abort()`）。
    final uploadPath = request.uploadFilePath;
    final fileBytes =
        uploadPath == null ? null : await readUploadFile(uploadPath);

    final req = await _client.openUrl(request.method, request.url);
    for (final entry in request.headers.entries) {
      req.headers.set(entry.key, entry.value);
    }

    if (uploadPath != null) {
      // 邊界只用「不變前綴 + 微秒時間戳」：同一請求內唯一即可，不必是密碼學隨機。
      final boundary =
          '----pathguide${DateTime.now().microsecondsSinceEpoch}';
      req.headers.set(
          'Content-Type', 'multipart/form-data; boundary=$boundary');
      req.add(buildMultipartBody(
        boundary: boundary,
        fields: request.fields ?? const <String, String>{},
        filename: File(uploadPath).uri.pathSegments.last,
        fileBytes: fileBytes!,
      ));
    } else if (request.jsonBody != null) {
      req.headers.contentType = ContentType.json;
      req.add(request.jsonBody!);
    }

    final res = await req.close();
    // 先收完位元組再解碼，`allowMalformed: true`：非 UTF-8 的 body（二進位垃圾、
    // 被截斷的壓縮內容）不該在這裡拋 `FormatException`。讓它變成替代字元往上走，
    // `HttpApi` 才會把它歸類成「回應不是契約的形狀」（`bad_response`，不可重試），
    // 而不是「連線不穩」（可重試）—— 重試一個壞掉的回應只會拿到同一個壞回應。
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
    }
    return TransportResponse(
        statusCode: res.statusCode,
        body: utf8.decode(bytes, allowMalformed: true));
  }
}
