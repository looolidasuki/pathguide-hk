import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/api/api_types.dart';

void main() {
  test('ApiFailure 帶機器可讀的 code 與是否可重試', () {
    const f = ApiFailure(code: 'network', message: '暫時連不上', retryable: true);
    expect(f.code, 'network');
    expect(f.retryable, isTrue);
    expect(f.toString(), contains('network'));
  });

  test('ApiNotAvailable 是不可重試的「尚未提供」', () {
    final f = ApiNotAvailable();
    expect(f.code, 'not_available');
    expect(f.retryable, isFalse);
    expect(f.message, isNotEmpty);
  });

  test('UploadFrameRequest 的 gps 可以缺席（室內錄製沒有定位）', () {
    final r = UploadFrameRequest(
      framePath: '/tmp/a.jpg',
      capturedAt: DateTime.utc(2026, 10, 23),
      modelVersion: '2026-10-02.stage2',
    );
    expect(r.latitude, isNull);
    expect(r.routeId, isNull);
  });
}
