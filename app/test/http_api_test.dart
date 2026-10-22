import 'dart:convert';

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
}
