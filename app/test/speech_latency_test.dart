import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/tts/speech_latency.dart';

void main() {
  test('adds native, Dart and TTS segments for one announcement', () {
    var now = DateTime.utc(2026, 11, 23, 12);
    final probe = SpeechLatencyProbe(clock: () => now, reportEvery: 0);
    final received = now;
    now = now.add(const Duration(milliseconds: 30)); // Dart 收到 → 提交
    probe.submitted(receivedAt: received, nativeMs: 380);
    now = now.add(const Duration(milliseconds: 220)); // 提交 → TTS 開始
    expect(probe.started(), closeTo(630, 1e-6));
    expect(probe.count, 1);
  });

  test('a start without a pending submission is not counted', () {
    final probe = SpeechLatencyProbe(reportEvery: 0);
    expect(probe.started(), isNull);
    expect(probe.count, 0);
  });

  test('cancel prevents pairing with the next unrelated start', () {
    var now = DateTime.utc(2026, 11, 23, 12);
    final probe = SpeechLatencyProbe(clock: () => now, reportEvery: 0);
    probe.submitted(receivedAt: now, nativeMs: 100);
    probe.cancel();
    now = now.add(const Duration(seconds: 5));
    expect(probe.started(), isNull);
    expect(probe.count, 0);
  });

  test('summary reports nearest-rank p50 and p95', () {
    var now = DateTime.utc(2026, 11, 23, 12);
    final probe = SpeechLatencyProbe(clock: () => now, reportEvery: 0);
    for (var i = 1; i <= 20; i++) {
      probe.submitted(receivedAt: now, nativeMs: i * 100.0);
      probe.started();
    }
    expect(probe.percentile(0.5), 1000);
    expect(probe.percentile(0.95), 1900);
    expect(probe.summary, 'n=20 p50=1000ms p95=1900ms');
  });
}
