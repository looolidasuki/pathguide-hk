import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/scene/live_scene_controller.dart';
import 'package:pathguide/scene/live_scene_signal.dart';
import 'package:pathguide/scene/scene_backend.dart';
import 'package:pathguide/tts/announcer.dart';
import 'package:pathguide/tts/speech_coordinator.dart';

const full = '畫面左邊有張木枱。中間見到一道門，右邊有張凳。';

class Backend implements SceneBackend {
  int calls = 0;
  final pending = <Completer<SceneReply>>[], ids = <String>[];
  @override
  Future<SceneReply> describe(
    Uint8List jpeg,
    String requestId, {
    bool Function()? isCurrent,
  }) {
    calls++;
    ids.add(requestId);
    final c = Completer<SceneReply>();
    pending.add(c);
    return c.future;
  }

  void finish({
    String text = full,
    bool usage = true,
    bool rejected = false,
    String? rejectionReason,
  }) {
    pending.last.complete(
      SceneReply.fromMap({
        'status': rejected ? 'rejected' : 'complete',
        'requestId': ids.last,
        if (!rejected) 'text': text,
        'rejectionReason': ?rejectionReason,
        'metrics': {
          'modelMs': 50,
          'usage': usage
              ? {
                  'prompt_tokens': 100,
                  'completion_tokens': 20,
                  'total_tokens': 120,
                }
              : null,
          'estimate': usage ? {'usd': 0.000052, 'notBillingCap': true} : null,
        },
      }, ids.last),
    );
  }
}

class Voice implements Speaker {
  final said = <String>[];
  int stops = 0;
  bool hold = false;
  Completer<void>? wait;
  @override
  Future<void> speak(String text) async {
    said.add(text);
    if (hold) wait = Completer<void>();
    await wait?.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (wait?.isCompleted == false) wait!.complete();
  }

  @override
  Future<List<String>> languages() async => ['zh-HK'];
}

class Harness {
  Harness(this.tester) {
    controller = LiveSceneController(
      capture: () async {
        captures++;
        return bytes.future;
      },
      backend: backend,
      speaker: voice,
      clock: () => now,
      cooldown: const Duration(seconds: 45),
      stableFor: const Duration(milliseconds: 700),
      maxSessionAttempts: 3,
    );
    controller.setAvailable(true);
    bytes.complete(Uint8List.fromList([1]));
  }
  final WidgetTester tester;
  final backend = Backend();
  final voice = Voice();
  int captures = 0, seq = 0;
  Completer<Uint8List?> bytes = Completer<Uint8List?>();
  DateTime now = DateTime(2026, 11, 8);
  late LiveSceneController controller;
  LiveSceneSignal signal({int luma = 40, double yaw = 0, double rate = 0}) =>
      LiveSceneSignal(
        sequence: ++seq,
        luma: List<int>.generate(
          64,
          (i) => i < 32 ? luma : (220 - luma).clamp(0, 255).toInt(),
        ),
        attitude: [
          0,
          0,
          math.sin(yaw * math.pi / 360),
          math.cos(yaw * math.pi / 360),
        ],
        rotationRate: rate,
      );
  Future<void> frame({int luma = 40, double yaw = 0, double rate = 0}) async {
    now = now.add(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    controller.observe(signal(luma: luma, yaw: yaw, rate: rate));
    await tester.pump();
  }

  Future<void> stable({int luma = 40, double yaw = 0, int frames = 8}) async {
    for (var i = 0; i < frames; i++) {
      await frame(luma: luma, yaw: yaw);
    }
  }
}

void main() {
  testWidgets(
    'previous successful request diagnostics survive a later quota failure without retaining text',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      await h.stable();
      final first = h.controller.describe();
      await tester.pump();
      final successfulId = h.backend.ids.single;
      h.backend.finish();
      await first;
      await h.stable(frames: 240);
      final second = h.controller.describe();
      await tester.pump();
      h.backend.pending.last.completeError(
        const SceneFailure('resource-exhausted'),
      );
      await second;
      expect(h.controller.backendStatus, '失敗');
      final data = h.controller.diagnostics;
      expect(data, contains(successfulId));
      expect(data, contains(h.backend.ids.last));
      expect(data, contains('後端結果：成功'));
      expect(data, contains('resource-exhausted'));
      expect(data, isNot(contains(full)));
      h.controller.dispose();
    },
  );
  testWidgets(
    'local speech probe uses no capture/backend attempt and survives camera freshness expiry',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      h.voice.hold = true;
      await h.stable();
      final probe = h.controller.testSpeech();
      await tester.pump();
      expect(h.voice.said, ['呢段係本機廣東話語音測試，唔係環境描述。']);
      expect(h.controller.canRequest, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(h.voice.wait!.isCompleted, isFalse);
      expect(h.controller.canDeliverSpeech, isTrue);
      h.voice.wait!.complete();
      await probe;
      expect(h.captures, 0);
      expect(h.backend.calls, 0);
      expect(h.controller.attempts, 0);
      h.controller.dispose();
    },
  );
  testWidgets(
    'a rejected late reply keeps separate backend and invalidation evidence without answer content',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      h.controller.setAutomatic(true);
      await h.stable();
      final requestId = h.backend.ids.single;
      expect(h.controller.backendStatus, '等待回覆');
      expect(h.controller.cooldownSeconds, greaterThan(40));
      await h.frame(yaw: 30, rate: 2.2);
      expect(h.controller.lastInvalidation, '快速轉向');
      h.backend.finish(rejected: true, rejectionReason: 'sentence-count');
      await tester.pump();
      expect(h.controller.backendStatus, '拒絕');
      expect(h.controller.rejectionReason, 'sentence-count');
      expect(h.controller.failure, 'rejected');
      expect(h.controller.automatic, isTrue);
      expect(h.controller.text, isNull);
      expect(h.voice.said, isEmpty);
      final report = h.controller.diagnostics;
      expect(report, contains(requestId));
      expect(report, contains('快速轉向'));
      expect(report, contains('sentence-count'));
      expect(report, contains('100／20／120'));
      expect(report, contains('0.000052'));
      expect(report, isNot(contains(full)));
      expect(h.controller.backendMs, isNotNull);
      await h.stable(yaw: 30, frames: 240);
      expect(h.backend.calls, 2);
      h.backend.finish();
      await tester.pump();
      expect(h.controller.diagnostics, contains('sentence-count'));
      h.controller.dispose();
    },
  );
  testWidgets(
    'rejection status survives motion and expiry; unknown reason content is not copied',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      await h.stable();
      final work = h.controller.describe();
      await tester.pump();
      h.backend.finish(
        rejected: true,
        rejectionReason: 'private upstream content',
      );
      await work;
      expect(h.controller.phase, '回覆被拒絕');
      final status = h.controller.status;
      await h.frame(yaw: 45, rate: 2.2);
      await tester.pump(const Duration(seconds: 21));
      expect(h.controller.status, status);
      expect(
        h.controller.diagnostics,
        isNot(contains('private upstream content')),
      );
    },
  );
  testWidgets(
    'manual mode does not trigger again after a scene change or cooldown',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      await h.stable();
      final work = h.controller.describe();
      await tester.pump();
      h.backend.finish();
      await work;
      await h.frame(yaw: 30, rate: 2.2);
      expect(h.controller.status, contains('場景模式關閉'));
      await h.stable(yaw: 30, frames: 240);
      expect(h.backend.calls, 1);
      expect(h.controller.cooldownSeconds, 0);
      h.controller.dispose();
    },
  );
  test('motion parsing rejects stale/missing/malformed evidence instead of guessing stability', () {
    final v = {
      'sequence': 1,
      'luma': List.filled(64, 40),
      'attitude': [0, 0, 0, 1],
      'rotationRate': 0,
      'motionFresh': true,
    };
    expect(LiveSceneSignal.parse(v), isNotNull);
    for (final bad in [
      {'motionFresh': false},
      {'luma': List.filled(64, -1)},
      {
        'attitude': [0, 0, 0, 0],
      },
      {
        'attitude': [0, 0, double.nan, 1],
      },
      {'rotationRate': double.infinity},
      {'sequence': -1},
    ]) {
      expect(LiveSceneSignal.parse({...v, ...bad}), isNull);
    }
  });
  testWidgets(
    'ordinary hand tremor keeps controls available and does not discard a paid reply',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      expect(h.controller.canRequest, isTrue);
      expect(h.controller.canDescribe, isFalse);
      h.controller.setAutomatic(true);
      for (var i = 0; i < 8; i++) {
        await h.frame(yaw: i.isEven ? 2 : -2, rate: 0.25);
      }
      expect(h.backend.calls, 1);
      expect(h.controller.automatic, isTrue);
      h.backend.finish();
      await tester.pump();
      expect(h.voice.said, [full]);
      await h.frame(yaw: 3, rate: 0.3);
      expect(h.controller.text, isNotNull);
      expect(h.controller.automatic, isTrue);
      await h.frame(yaw: 45, rate: 2.2);
      expect(h.controller.text, isNull);
      expect(h.controller.automatic, isTrue);
      h.controller.dispose();
    },
  );
  testWidgets(
    'manual request waits locally for stable handheld frames before any capture/upload',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      final pending = h.controller.describe();
      await tester.pump();
      expect(h.captures, 0);
      expect(h.backend.calls, 0);
      await h.frame(rate: 1);
      await h.stable();
      expect(h.captures, 1);
      expect(h.backend.calls, 1);
      h.backend.finish();
      await pending;
      expect(h.voice.said, [full]);
      h.controller.dispose();
    },
  );
  testWidgets(
    'unstable manual request expires without photo, cost debit, or automatic retry',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      final pending = h.controller.describe();
      await tester.pump();
      for (var i = 0; i < 15; i++) {
        await h.frame(yaw: i * 10, rate: 1);
      }
      await pending;
      expect(h.captures, 0);
      expect(h.backend.calls, 0);
      expect(h.controller.attempts, 0);
      expect(h.controller.failure, 'not-stable');
      expect(h.controller.canRequest, isFalse);
      expect(h.controller.cooldownSeconds, greaterThan(0));
      h.controller.dispose();
    },
  );
  testWidgets(
    'small pose drift during encoding and reply does not erase a valid snapshot',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      h.bytes = Completer<Uint8List?>();
      await h.stable();
      final pending = h.controller.describe();
      await tester.pump();
      await h.frame(yaw: 6, rate: 0.3);
      expect(h.controller.stable, isTrue);
      h.bytes.complete(Uint8List(1));
      await tester.pump();
      expect(h.backend.calls, 1);
      h.backend.finish();
      await pending;
      expect(h.voice.said, [full]);
      expect(h.controller.text, full);
      h.controller.dispose();
    },
  );
  testWidgets(
    'first stable scene triggers once; unchanged video never polls cloud even after cooldown',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      h.controller.setAutomatic(true);
      await h.frame(rate: 1);
      expect(h.backend.calls, 0);
      await h.stable();
      expect(h.backend.calls, 1);
      h.backend.finish();
      await tester.pump();
      expect(h.voice.said, [full]);
      await h.stable(frames: 240);
      expect(h.backend.calls, 1);
      expect(h.controller.automatic, isTrue);
      h.controller.dispose();
    },
  );
  testWidgets(
    'important visual change waits for stability and cooldown; audio omits identical sentences',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      h.controller.setAutomatic(true);
      await h.stable();
      h.backend.finish();
      await tester.pump();
      await h.stable(luma: 100);
      expect(h.backend.calls, 1);
      await h.stable(luma: 100, frames: 230);
      expect(h.backend.calls, 2);
      h.backend.finish(text: '畫面左邊有張木枱。右邊見到一個櫃。');
      await tester.pump();
      expect(h.voice.said.last, '右邊見到一個櫃。');
      h.controller.dispose();
    },
  );
  testWidgets(
    'turn invalidates reply and keeps single in flight, then needs stable evidence',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      h.controller.setAutomatic(true);
      await h.stable();
      expect(h.backend.calls, 1);
      await h.frame(yaw: 30, rate: 2.2);
      await h.stable(yaw: 30);
      expect(h.backend.calls, 1);
      h.backend.finish();
      await tester.pump();
      expect(h.voice.said, isEmpty);
      expect(h.controller.text, isNull);
      await h.stable(yaw: 30, frames: 230);
      expect(h.backend.calls, 2);
      h.backend.finish();
      await tester.pump();
      h.controller.dispose();
    },
  );
  testWidgets(
    'stop before capture returns prevents upload and does not debit an attempt',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      h.bytes = Completer<Uint8List?>();
      await h.stable();
      final pending = h.controller.describe();
      await tester.pump();
      h.controller.setAvailable(false);
      h.bytes.complete(Uint8List(1));
      await pending;
      expect(h.backend.calls, 0);
      expect(h.controller.attempts, 0);
      h.controller.setAvailable(true);
      expect(h.controller.automatic, isFalse);
      h.controller.dispose();
    },
  );
  testWidgets(
    'unknown usage blocks new analysis while mode intent remains on; turn withdraws speech',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      h.controller.setAutomatic(true);
      await h.stable();
      h.voice.wait = Completer<void>();
      h.backend.finish(usage: false);
      await tester.pump();
      expect(h.controller.usageUnknown, isTrue);
      expect(h.controller.automatic, isTrue);
      expect(h.controller.restricted, isTrue);
      expect(h.voice.said, [full]);
      await h.frame(yaw: 45, rate: 2.2);
      expect(h.controller.text, isNull);
      expect(h.voice.stops, greaterThan(0));
      h.controller.dispose();
    },
  );
  testWidgets(
    'exhausted backend never auto repeats and leaves local camera availability intact',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      h.controller.setAutomatic(true);
      await h.stable();
      h.backend.pending.last.completeError(
        const SceneFailure('resource-exhausted'),
      );
      await tester.pump();
      expect(h.controller.automatic, isTrue);
      expect(h.controller.restricted, isTrue);
      expect(h.controller.available, isTrue);
      await h.stable(luma: 100, frames: 240);
      expect(h.backend.calls, 1);
      h.controller.dispose();
    },
  );
  testWidgets(
    'stale frame cancels reply; background/overlay need explicit auto re-enable',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      h.controller.setAutomatic(true);
      await h.stable();
      h.now = h.now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      h.backend.finish();
      await tester.pump();
      expect(h.voice.said, isEmpty);
      h.controller.interrupt();
      expect(h.controller.automatic, isFalse);
      h.controller.setAvailable(false);
      h.controller.setAvailable(true);
      await h.stable(luma: 100, frames: 240);
      expect(h.backend.calls, 1);
      h.controller.dispose();
    },
  );
  testWidgets(
    'three attempts shared by manual and automatic cannot produce a fourth request',
    (tester) async {
      final h = Harness(tester);
      addTearDown(h.controller.dispose);
      h.controller.setAutomatic(true);
      for (var i = 0; i < 3; i++) {
        await h.stable(luma: 40 + i * 60, frames: i == 0 ? 8 : 240);
        expect(h.backend.calls, i + 1);
        h.backend.finish();
        await tester.pump();
      }
      expect(h.controller.automatic, isTrue);
      expect(h.controller.restricted, isTrue);
      await h.stable(luma: 240, frames: 240);
      await h.controller.describe();
      expect(h.backend.calls, 3);
      expect(h.controller.canDescribe, isFalse);
      h.controller.dispose();
    },
  );
  testWidgets(
    'detector expiry withdraws only detector speech and preserves scene output',
    (tester) async {
      final output = Voice()..hold = true;
      final voice = SpeechCoordinator(output);
      final scene = voice.channel(SpeechChannel.scene).speak(full);
      await tester.pump();
      final stops = output.stops;
      await voice.stopOwned(SpeechChannel.environment);
      expect(output.stops, stops);
      expect(output.wait!.isCompleted, isFalse);
      await voice.stop();
      await scene;
    },
  );
  testWidgets(
    'scene cannot preempt local alerts or navigation and is never queued',
    (tester) async {
      final output = Voice()..hold = true;
      final voice = SpeechCoordinator(output);
      final local = voice.channel(SpeechChannel.environment).speak('物件提示');
      await tester.pump();
      await voice.channel(SpeechChannel.scene).speak(full);
      expect(output.said, ['物件提示']);
      final nav = voice.channel(SpeechChannel.navigation).speak('導航');
      await tester.pump();
      expect(output.said, ['物件提示', '導航']);
      await voice.stop();
      await local;
      await nav;
    },
  );
}
