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

/// 逾時一律換成這個：可重試的 `network`。
const ApiFailure _timeoutFailure = ApiFailure(
  code: 'network',
  message: '連線太久沒有回應，請稍後再試',
  retryable: true,
);

/// 逾時時**真的**中止在途請求的把手。
///
/// 存在的理由：`Future.timeout` 只是「不再等」，底下的請求照樣在跑。上傳一幀
/// JPEG 時那條連線會繼續把 body 流完，而呼叫方（Task 9 的重試隊列）已經把同一格
/// 重新排進隊列 —— 後端於是收到兩次 `/v1/frames`，產生兩條一模一樣的紀錄。
/// [HttpClientRequest.abort] 是 `dart:io` 現成的取消句柄（`abort([exception,
/// stackTrace])`，`http.dart` 的 `HttpClientRequest`）：它 destroy 掉連線，之後
/// `IOSink` 的方法（含 `add()`）都不再生效，body 不會繼續流。
///
/// 這個類只做三件在測試裡可以釘死、且不碰網絡的事：
///  1. 請求物件一到手就 [attach] 中止動作；
///  2. 逾時通知 [onTimeout] **只**觸發一次中止（重複通知不會再叫一次）；
///  3. 逾時先於請求物件發生時（`openUrl()` 還在 pending），拿到請求的那一刻補
///     中止 —— 否則那段時間差就會留下一條永遠不會被中止的上傳。
///
/// `abort()` 自己拋的錯一律吞掉：它若漏出去，呼叫方看到的會是那個錯，而不是
/// 逾時該有的 [ApiFailure]（呼叫方要靠 `retryable` 決定要不要重送）。
class RequestAbortHandle {
  void Function()? _onAbort;
  bool _timedOut = false;
  bool _aborted = false;

  /// 登記「怎麼中止目前這個請求」。已經逾時過就立刻中止這一個。
  void attach(void Function() onAbort) {
    _onAbort = onAbort;
    if (_timedOut) _abortOnce();
  }

  /// 逾時路徑呼叫：立起標記並中止（請求還沒出現就等 [attach] 補上）。
  void onTimeout() {
    _timedOut = true;
    _abortOnce();
  }

  void _abortOnce() {
    if (_aborted) return;
    final onAbort = _onAbort;
    // 請求物件還沒出現：等 [attach] 補上（那時 `_timedOut` 已經是 true）。
    if (onAbort == null) return;
    // 先立旗再呼叫：中止動作自己拋錯也不會導致被中止第二次。
    _aborted = true;
    try {
      onAbort();
    } catch (_) {
      // 見類別說明：刻意吞掉。本層刻意不 import Flutter（拿不到 `debugPrint`），
      // 也別為了一行 log 把純 Dart 的傳輸層綁上 framework。
    }
  }
}

/// 為整個請求加上時限；逾時**先中止在途請求**，再換成**可重試**的 [ApiFailure]
/// （`network`）。
///
/// 順序不能顛倒：先 [RequestAbortHandle.onTimeout] 再 `throw`。中止若失敗或拋錯，
/// 錯在 handle 裡被吞掉，呼叫方看到的仍是 `network`／可重試。
///
/// 為什麼要中止而不是放手（[RequestAbortHandle] 有完整理由）：本層最重的請求是
/// 上傳一幀 JPEG，逾時後若只是「不再等」，那條連線會繼續串流，而重試隊列同時
/// 會把同一格再送一次 → 重複的 `/v1/frames`。逾時發生在兩段時序上都要顧到，
/// 用同一個 handle 就夠：
///  * 請求物件還沒出現（`openUrl()` 仍在 pending）：`attach` 時補中止；
///  * 請求物件已出現、`close()`／body streaming 還在跑：立刻中止。
/// 已經收到回應（`close()` 完成、正在讀 body）之後，`HttpClientRequest.abort`
/// 在 `dart:io` 內部是 no-op（回應的 completer 已完成）；那一段也不需要中止 ——
/// 伺服器已經把回應寫出來了，沒有半截上傳還在流。
///
/// 獨立成頂層函式（而不是寫死在 [HttpClientTransport.send] 裡）是為了可測：
/// 傳一個永不完成的 Future 進來，就能在不碰真網的前提下釘住「逾時 → 先中止 →
/// 可重試」這條轉換。
Future<TransportResponse> withRequestTimeout(
  Future<TransportResponse> Function() work, {
  Duration timeout = HttpClientTransport.requestTimeout,
  RequestAbortHandle? abortInFlight,
}) async {
  try {
    return await work().timeout(
      timeout,
      onTimeout: () {
        abortInFlight?.onTimeout();
        throw _timeoutFailure;
      },
    );
  } on TimeoutException {
    // 只會來自 `work()` 自己（例如它內部又套了一層 `.timeout`）；逾時那條路徑
    // 走上面的 `onTimeout`，那裡已經把在途請求中止掉了。
    throw _timeoutFailure;
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
  Future<TransportResponse> send(TransportRequest request) {
    // 一個請求一個 handle：逾時時它才知道要中止哪一個（見 [RequestAbortHandle]）。
    final abort = RequestAbortHandle();
    return withRequestTimeout(
      () => _send(request, abort),
      abortInFlight: abort,
    );
  }

  Future<TransportResponse> _send(
    TransportRequest request,
    RequestAbortHandle abort,
  ) async {
    // 先讀檔案、再開連線：檔案不見時連線都還沒建，就不會留下一個「請求已建立、
    // 卻註定沒人用」的連線，也不必有誰記得去中止它。
    final uploadPath = request.uploadFilePath;
    final fileBytes =
        uploadPath == null ? null : await readUploadFile(uploadPath);

    final req = await _client.openUrl(request.method, request.url);
    // 從這一行起，逾時就有東西可以真的中止。若逾時在這之前就發生了（`openUrl`
    // 還在 pending），`attach` 看到標記會立刻補一次中止，不讓它流下去。
    abort.attach(() {
      req.abort(TimeoutException('請求逾時，已在傳輸層中止連線'));
    });
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
