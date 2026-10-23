import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/api/api_types.dart';
import 'package:pathguide/api/http_api.dart';
import 'package:pathguide/api/http_transport.dart';

/// 假傳輸層：**測試一律不碰真網**（Global Constraints）。
/// 它把每次請求原樣留下來，於是「打了哪個 URL、帶了什麼標頭與欄位」可以直接斷言。
class _FakeTransport implements HttpTransport {
  final List<TransportRequest> requests = <TransportRequest>[];
  TransportResponse response =
      const TransportResponse(statusCode: 200, body: '{}');

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    requests.add(request);
    return response;
  }
}

void main() {
  late _FakeTransport transport;
  late HttpApi api;

  setUp(() {
    transport = _FakeTransport();
    api = HttpApi(
        baseUrl: Uri.parse('https://api.example.test'), transport: transport);
  });

  /// 介面上**每一個**帶 `token` 參數的方法都跑一次，回傳每次請求帶的
  /// `Authorization`（`null` 表示沒帶）。
  ///
  /// 用「跑一輪」而不是逐一斷言，是為了讓「哪個方法忘了把自己的 token 交上去」
  /// 在這裡就紅掉，而不是等 Task 9 拿到 401 才發現。
  Future<List<String?>> authHeadersFor(String token) async {
    final from = transport.requests.length;
    final calls = <Future<Object?> Function()>[
      () async => api.fetchSettings(token: token),
      () async {
        await api.saveSettings(
            token: token, settings: const <String, Object?>{});
        return null;
      },
      () async => api.visionQuery(
          token: token,
          imageSha256: 'sha',
          question: 'q',
          locale: 'zh-HK'),
      () async =>
          api.planRoute(token: token, utterance: 'u', locale: 'zh-HK'),
      () async => api.refresh(token: token),
      () async => api.uploadFrame(
            token: token,
            request: UploadFrameRequest(
              framePath: '/tmp/frame_1.jpg',
              capturedAt: DateTime.utc(2026, 10, 23),
              modelVersion: 'm1',
            ),
          ),
    ];
    for (final call in calls) {
      await call();
    }
    return <String?>[
      for (final r in transport.requests.skip(from)) r.headers['Authorization'],
    ];
  }

  test('★ login 打的是 POST /v1/auth/login 且帶 JSON body', () async {
    transport.response = TransportResponse(
      statusCode: 200,
      body: jsonEncode(<String, Object?>{
        'userId': 'u1',
        'token': 'tk',
        'expiresAt': '2026-12-31T00:00:00Z',
      }),
    );

    final s = await api.login(method: 'email', credential: 'c');

    final r = transport.requests.single;
    expect(r.method, 'POST');
    expect(r.url.toString(), 'https://api.example.test/v1/auth/login');
    expect(jsonDecode(utf8.decode(r.jsonBody!)),
        <String, Object?>{'method': 'email', 'credential': 'c'});
    expect(s.userId, 'u1');
    expect(s.token, 'tk');
    expect(s.expiresAt, DateTime.utc(2026, 12, 31));
  });

  test('★ 401 映射成可重取的 AuthExpired（code=auth_expired）', () async {
    transport.response =
        const TransportResponse(statusCode: 401, body: '{"code":"expired"}');
    await expectLater(
      api.fetchSettings(token: 't'),
      throwsA(isA<ApiFailure>()
          .having((f) => f.code, 'code', 'auth_expired')
          .having((f) => f.retryable, 'retryable', isTrue)),
    );
  });

  test('★ 5xx 不可重試、4xx 也不可重試，只有 408/429 可', () async {
    transport.response = const TransportResponse(statusCode: 500, body: '');
    await expectLater(
        api.latestModel(),
        throwsA(isA<ApiFailure>()
            .having((f) => f.retryable, 'retryable', isFalse)));

    transport.response = const TransportResponse(statusCode: 429, body: '');
    await expectLater(
        api.latestModel(),
        throwsA(isA<ApiFailure>()
            .having((f) => f.retryable, 'retryable', isTrue)));
  });

  test('★ 上傳走 multipart 欄位，檔名與 modelVersion 都在', () async {
    transport.response = const TransportResponse(
        statusCode: 200, body: '{"frameId":"f1","status":"queued"}');
    final receipt = await api.uploadFrame(
      token: 't',
      request: UploadFrameRequest(
        framePath: '/tmp/frame_1.jpg',
        capturedAt: DateTime.utc(2026, 10, 23, 1, 2, 3),
        modelVersion: '2026-10-02.stage2',
        routeId: 'r1',
      ),
    );

    final r = transport.requests.single;
    expect(r.url.path, '/v1/frames');
    expect(r.uploadFilePath, '/tmp/frame_1.jpg');
    expect(r.fields!['modelVersion'], '2026-10-02.stage2');
    expect(r.fields!['routeId'], 'r1');
    expect(r.fields!['capturedAt'], '2026-10-23T01:02:03.000Z');
    // 沒有定位就不要送這兩個欄位（室內錄製沒有 GPS）。
    expect(r.fields!.containsKey('lat'), isFalse);
    expect(r.fields!.containsKey('lng'), isFalse);
    expect(receipt.frameId, 'f1');
    expect(receipt.status, 'queued');
  });

  test('有 token 時帶 Authorization，沒有則不帶', () async {
    api.setToken('abc');
    transport.response = const TransportResponse(statusCode: 200, body: '{}');
    await api.latestModel();
    expect(transport.requests.single.headers['Authorization'], 'Bearer abc');

    api.setToken(null);
    await api.latestModel();
    expect(transport.requests.last.headers.containsKey('Authorization'), isFalse);
  });

  // 以下兩條不在 brief 的樣板裡，是控制器裁定的落地證明（task-7 報告有記）。
  test('★ 缺 downloadUrl／sha256 是空字串，不是 "null"（控制器裁定）', () async {
    transport.response = TransportResponse(
      statusCode: 200,
      body: jsonEncode(<String, Object?>{
        'version': '2026-10-02.stage2',
        'bytes': 42,
        'modelClassCount': 3,
        'inputSize': 320,
        'modelClassIds': <int>[1, 2, 3],
      }),
    );

    final env = await api.latestModel();

    expect(env.downloadUrl, '');
    expect(env.sha256, '');
    // `'null'` 會讓呼叫方的 `isEmpty` 判斷失守，是這裡要擋掉的具體錯誤。
    expect(env.downloadUrl, isNot('null'));
    expect(env.sha256, isNot('null'));
    expect(env.bytes, 42);
  });

  test('★ 其他 4xx → client 不可重試；空 body（204）當成 {}', () async {
    transport.response = const TransportResponse(statusCode: 404, body: '');
    await expectLater(
      api.fetchSettings(token: 't'),
      throwsA(isA<ApiFailure>()
          .having((f) => f.code, 'code', 'client')
          .having((f) => f.retryable, 'retryable', isFalse)),
    );

    transport.response = const TransportResponse(statusCode: 204, body: '');
    expect(await api.fetchSettings(token: 't'), isEmpty);
  });

  // ---- Fix round 1：以下釘住 review 的五條發現 -------------------------------

  test('★ 200 但 body 是 HTML（Wi-Fi 登入頁）→ bad_response 不可重試', () async {
    // 商場／電信商 Wi-Fi 的登入頁就是這樣回來的：200 + HTML。
    // 以前 `jsonDecode` 的 `FormatException` 會穿過 `on ApiFailure`，
    // 使用者只聽到安靜 —— 現在必須是一個有話可說的失敗。
    transport.response = const TransportResponse(
      statusCode: 200,
      body: '<html><body>請先登入本商場 Wi-Fi</body></html>',
    );

    await expectLater(
      api.latestModel(),
      throwsA(isA<ApiFailure>()
          .having((f) => f.code, 'code', 'bad_response')
          .having((f) => f.retryable, 'retryable', isFalse)
          // 訊息會被 TTS 唸出來，不能是空字串或型別名。
          .having((f) => f.message, 'message', isNotEmpty)),
    );
    expect(transport.requests, hasLength(1), reason: '不該自己偷偷重試');
  });

  test('★ 合法 JSON 但形狀不對 → bad_response（不漏 TypeError／CastError）',
      () async {
    // 1) 頂層不是物件。
    transport.response =
        const TransportResponse(statusCode: 200, body: '[1,2,3]');
    await expectLater(
      api.latestModel(),
      throwsA(isA<ApiFailure>()
          .having((f) => f.code, 'code', 'bad_response')
          .having((f) => f.retryable, 'retryable', isFalse)),
    );

    // 2) `modelClassIds` 裡混了非數字（`(id as num).toInt()` 會拋 TypeError）。
    transport.response = TransportResponse(
      statusCode: 200,
      body: jsonEncode(<String, Object?>{'modelClassIds': <Object?>[1, 'x']}),
    );
    await expectLater(
      api.latestModel(),
      throwsA(isA<ApiFailure>().having((f) => f.code, 'code', 'bad_response')),
    );

    // 3) 數值欄位是字串。
    transport.response = TransportResponse(
      statusCode: 200,
      body: jsonEncode(<String, Object?>{'bytes': 'many'}),
    );
    await expectLater(
      api.latestModel(),
      throwsA(isA<ApiFailure>().having((f) => f.code, 'code', 'bad_response')),
    );
  });

  test('★ 每呼叫的 token 優先於 setToken；空的回落到已存的那一個', () async {
    transport.response = const TransportResponse(statusCode: 200, body: '{}');

    // 存一個過期令牌，然後每次呼叫都傳一個新的：新的一定要贏，
    // 否則請求會帶著舊令牌出去 → 401 `auth_expired`（可重試）→ 無限重試。
    api.setToken('stale');
    final fresh = await authHeadersFor('fresh');
    expect(fresh, hasLength(6), reason: '有帶 token 的方法漏了一個沒跑');
    expect(fresh, everyElement('Bearer fresh'));

    // 空字串 = 這次沒有指定 → 回落 `setToken` 存的那個，不是「不帶」。
    final fallback = await authHeadersFor('');
    expect(fallback, hasLength(6));
    expect(fallback, everyElement('Bearer stale'));

    // 兩邊都沒有 → 一個 Authorization 都不送。
    api.setToken(null);
    final none = await authHeadersFor('');
    expect(none, hasLength(6));
    expect(none, everyElement(isNull));
  });

  test('★ 整段請求逾時 → 可重試的 network（不會永遠 pending）', () async {
    // 永不完成的請求：模擬「伺服器接受了連線，卻一個位元組都不回」。
    // `connectionTimeout` 擋不住這種情況（它管的是連線建不起來）。
    final stalled = Completer<TransportResponse>();
    await expectLater(
      withRequestTimeout(() => stalled.future,
          timeout: const Duration(milliseconds: 20)),
      throwsA(isA<ApiFailure>()
          .having((f) => f.code, 'code', 'network')
          .having((f) => f.retryable, 'retryable', isTrue)),
    );

    // 預設時限必須存在且有限（走路中的人等不到 10 分鐘，也不該無限等）。
    expect(HttpClientTransport.requestTimeout, const Duration(seconds: 30));
  });

  test('★ 上傳的檔案不見了 → missing_file 不可重試（不是 PathNotFoundException）',
      () async {
    // 相對路徑：`flutter test` 的 cwd 是套件根目錄，這個名字保證不存在。
    final missing =
        'test/no_such_frame_${DateTime.now().microsecondsSinceEpoch}.jpg';

    await expectLater(
      readUploadFile(missing),
      throwsA(isA<ApiFailure>()
          .having((f) => f.code, 'code', 'missing_file')
          .having((f) => f.retryable, 'retryable', isFalse)),
    );
  });

  test('檔案在 → 位元組原樣回傳（成功路徑沒變）', () async {
    // 不假設 cwd 一定是套件根目錄，兩種擺法都試。
    const candidates = <String>['pubspec.yaml', 'app/pubspec.yaml'];
    final path = candidates.firstWhere((p) => File(p).existsSync(),
        orElse: () => '');
    expect(path, isNotEmpty, reason: '找不到 pubspec.yaml，cwd 假設不成立');

    final bytes = await readUploadFile(path);
    expect(bytes, isNotEmpty);
    expect(utf8.decode(bytes), contains('name: pathguide'));
  });

  group('multipart 框線（純函式，不經網絡）', () {
    const boundary = '----pathguideTESTBOUNDARY';
    const fileBytes = <int>[0xFF, 0xD8, 0xFF, 0x00, 0x7F, 0x80];

    test('★ 逐位元組：每欄位的 Content-Disposition／空行／值／CRLF + 原樣檔案 + 收尾',
        () {
      final body = buildMultipartBody(
        boundary: boundary,
        fields: const <String, String>{
          'capturedAt': '2026-10-23T01:02:03.000Z',
          'modelVersion': '2026-10-02.stage2',
        },
        filename: 'frame_1.jpg',
        fileBytes: fileBytes,
      );

      // 一行一段地寫出**期望的線上格式**（`join()` 讓它不必是常數運算式，
      // 也就避開 `prefer_const_declarations` 與「跨閉包 const」的糾纏）。
      final head = <String>[
        '--$boundary\r\n',
        'Content-Disposition: form-data; name="capturedAt"\r\n\r\n',
        '2026-10-23T01:02:03.000Z\r\n',
        '--$boundary\r\n',
        'Content-Disposition: form-data; name="modelVersion"\r\n\r\n',
        '2026-10-02.stage2\r\n',
        '--$boundary\r\n',
        'Content-Disposition: form-data; name="frame"; '
            'filename="frame_1.jpg"\r\n',
        'Content-Type: image/jpeg\r\n\r\n',
      ].join();
      final headBytes = utf8.encode(head);
      final tailBytes = utf8.encode('\r\n--$boundary--\r\n');

      // 1) 長度先對：多一個或少一個 `\r\n` 都算錯。
      expect(body.length,
          headBytes.length + fileBytes.length + tailBytes.length);
      // 2) 文字部分（開頭 `--boundary\r\n`、每個欄位的 name、空行、值）
      //    逐位元組相同。
      expect(body.sublist(0, headBytes.length), headBytes);
      expect(utf8.decode(body.sublist(0, headBytes.length)), head);
      // 3) 檔案位元組**原樣**接在 head 之後，落在正確位移、一個都沒被編碼
      //    （0xFF／0xD8 過不了 UTF-8，若被編碼這裡一定紅）。
      expect(body.sublist(headBytes.length,
          headBytes.length + fileBytes.length), fileBytes);
      // 4) 收尾是 `\r\n--boundary--\r\n`。
      expect(body.sublist(body.length - tailBytes.length), tailBytes);
    });

    test('沒有文字欄位時仍是合法 multipart（只有檔案段）', () {
      const onlyBytes = <int>[1, 2, 3];
      final body = buildMultipartBody(
        boundary: 'B',
        fields: const <String, String>{},
        filename: 'f.jpg',
        fileBytes: onlyBytes,
      );
      final text = utf8.decode(body, allowMalformed: true);

      expect(text, startsWith('--B\r\n'));
      expect(
          text,
          contains('Content-Disposition: form-data; name="frame"; '
              'filename="f.jpg"\r\n'));
      expect(text, endsWith('\r\n--B--\r\n'));

      final tailLength = utf8.encode('\r\n--B--\r\n').length;
      final start = body.length - tailLength - onlyBytes.length;
      expect(body.sublist(start, start + onlyBytes.length), onlyBytes);
    });
  });
}
