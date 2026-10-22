import 'dart:convert';
import 'dart:io';

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

/// 真正的 HTTP 實現（`dart:io` `HttpClient`）。
///
/// multipart 手寫而不是靠套件：邊界字串用固定前綴＋時間戳，內容只有
/// 「文字欄位 + 一個二進位檔」這種最簡情況，不值得為它加依賴。
class HttpClientTransport implements HttpTransport {
  HttpClientTransport({HttpClient? client}) : _client = _defaultClient(client);

  /// 預設 10 秒連線逾時：訪客／離線路徑不應該被一個連不上的後端拖住啟動
  /// （Global Constraints：任何 API 失敗都不得阻塞啟動）。
  /// 外部注入的 `client` 原樣使用，不動它的設定。
  static HttpClient _defaultClient(HttpClient? client) =>
      client ??
      (HttpClient()..connectionTimeout = const Duration(seconds: 10));

  final HttpClient _client;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final req = await _client.openUrl(request.method, request.url);
    for (final entry in request.headers.entries) {
      req.headers.set(entry.key, entry.value);
    }

    if (request.uploadFilePath != null) {
      // 邊界只用「不變前綴 + 微秒時間戳」：同一請求內唯一即可，不必是密碼學隨機。
      final boundary =
          '----pathguide${DateTime.now().microsecondsSinceEpoch}';
      req.headers.set(
          'Content-Type', 'multipart/form-data; boundary=$boundary');
      final file = File(request.uploadFilePath!);
      final bytes = await file.readAsBytes();
      final head = StringBuffer();
      // 用 `for` 而不是 `forEach(函數字面量)`：`avoid_function_literals_in_foreach_calls`
      // 在 `package:lints` 的 core 裡（`flutter_lints` 間接引入），門禁是 0 問題。
      final fields = request.fields ?? const <String, String>{};
      for (final entry in fields.entries) {
        head.write('--$boundary\r\n');
        head.write('Content-Disposition: form-data; name="${entry.key}"'
            '\r\n\r\n');
        head.write('${entry.value}\r\n');
      }
      head.write('--$boundary\r\n');
      head.write('Content-Disposition: form-data; name="frame"; '
          'filename="${file.uri.pathSegments.last}"\r\n');
      head.write('Content-Type: image/jpeg\r\n\r\n');
      req.add(utf8.encode(head.toString()));
      req.add(bytes);
      req.add(utf8.encode('\r\n--$boundary--\r\n'));
    } else if (request.jsonBody != null) {
      req.headers.contentType = ContentType.json;
      req.add(request.jsonBody!);
    }

    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    return TransportResponse(statusCode: res.statusCode, body: body);
  }
}
