import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/scene/live_scene_controller.dart';
import 'package:pathguide/scene/live_scene_signal.dart';
import 'package:pathguide/scene/scene_backend.dart';

import 'live_scene_test.dart' as legacy;

const overview = '左邊有張木枱。中間見到一道門。';
const update = '右邊見到一道門。';
const table = {'category': 'table', 'position': 'left', 'detail': '木枱'};
const door = {'category': 'door', 'position': 'right', 'detail': '打開嘅門'};

class ModeBackend implements SceneModeBackend {
  final modes = <String>[], ids = <String>[];
  final pending = <Completer<SceneReply>>[];
  @override
  Future<SceneReply> describe(
    Uint8List jpeg,
    String id, {
    bool Function()? isCurrent,
  }) => throw StateError('v1 unexpectedly used');
  @override
  Future<SceneReply> describeMode(
    Uint8List jpeg,
    String id, {
    required String mode,
    bool Function()? isCurrent,
  }) {
    modes.add(mode);
    ids.add(id);
    final c = Completer<SceneReply>();
    pending.add(c);
    return c.future;
  }

  void finish({
    List<Map<String, String>> facts = const [table],
    String? text,
    Map<String, int>? limits,
  }) {
    pending.last.complete(
      SceneReply.fromMap({
        'requestId': ids.last,
        'status': 'complete',
        'mode': modes.last,
        'text': text ?? (modes.last == 'overview' ? overview : update),
        'observations': facts,
        'limits': ?limits,
        'metrics': {
          'modelMs': 1500,
          'usage': {
            'prompt_tokens': 400,
            'completion_tokens': 100,
            'total_tokens': 500,
          },
          'estimate': {'usd': 0.00024, 'notBillingCap': true},
        },
      }, ids.last),
    );
  }
}

class StatusBackend extends ModeBackend implements SceneStatusBackend {
  final status = Completer<SceneAccountStatus>();
  int reads = 0;
  @override
  Future<SceneAccountStatus> readStatus() {
    reads++;
    return status.future;
  }
}

class H {
  H(this.tester, {ModeBackend? backend}) : b = backend ?? ModeBackend() {
    c = LiveSceneController(
      capture: () async {
        captures++;
        return Uint8List(1);
      },
      backend: b,
      speaker: v,
      clock: () => now,
    );
    c.setAvailable(true);
  }
  final WidgetTester tester;
  final ModeBackend b;
  final v = legacy.Voice();
  late LiveSceneController c;
  DateTime now = DateTime(2026, 11, 8);
  int seq = 0, captures = 0;
  Future<void> frame({
    double yaw = 0,
    double rate = 0.2,
    int shift = 0,
    int contrast = 40,
  }) async {
    now = now.add(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    c.observe(
      LiveSceneSignal(
        sequence: ++seq,
        luma: List<int>.generate(
          64,
          (i) => ((i < 32 ? contrast : 220 - contrast) + shift)
              .clamp(0, 255)
              .toInt(),
        ),
        attitude: [
          0,
          0,
          math.sin(yaw * math.pi / 360),
          math.cos(yaw * math.pi / 360),
        ],
        rotationRate: rate,
      ),
    );
    await tester.pump();
  }

  Future<void> frames(
    int n, {
    double yaw = 0,
    double rate = 0.2,
    int shift = 0,
    int contrast = 40,
  }) async {
    for (var i = 0; i < n; i++) {
      await frame(yaw: yaw, rate: rate, shift: shift, contrast: contrast);
    }
  }
}

void main() {
  test('100 request allowance accepted, 101 fails closed', () {
    final values = {
      'count': 32,
      'maxRequests': 100,
      'spentMicroUsd': 13331,
      'budgetMicroUsd': 500000,
      'windowRemaining': 68,
      'expiresAtMs': 1794620000000,
    };
    expect(SceneTrialLimits.parse(values)!.maxRequests, 100);
    expect(SceneTrialLimits.parse({...values, 'maxRequests': 101}), isNull);
  });
  test(
    'structured quota details keep only allowlisted reasons and valid limits',
    () {
      final error = SceneFailure.fromBackend('resource-exhausted', {
        'beforeProvider': true,
        'stopReason': 'budget-reserve',
        'limits': {
          'count': 16,
          'maxRequests': 50,
          'spentMicroUsd': 7861,
          'budgetMicroUsd': 10000,
          'windowRemaining': 34,
          'expiresAtMs': 0,
        },
        'private': 'not rendered',
      });
      expect(error.beforeProvider, isTrue);
      expect(error.stopReason, 'budget-reserve');
      final message = sceneStopMessage(error.stopReason, error.limits);
      expect(message, contains('0.002139'));
      expect(message, contains('0.002458'));
      expect(message, isNot(contains('許可需核對')));
      final larger = SceneFailure.fromBackend('resource-exhausted', {
        'limits': {
          'count': 16,
          'maxRequests': 50,
          'spentMicroUsd': 7861,
          'budgetMicroUsd': 500000,
          'windowRemaining': 34,
          'expiresAtMs': 0,
        },
      });
      expect(larger.limits!.budgetMicroUsd, 500000);
      expect(
        SceneFailure.fromBackend('resource-exhausted', {
          'limits': {
            'count': 16,
            'maxRequests': 50,
            'spentMicroUsd': 7861,
            'budgetMicroUsd': 500001,
            'windowRemaining': 34,
            'expiresAtMs': 0,
          },
        }).limits,
        isNull,
      );
      expect(
        SceneFailure.fromBackend('resource-exhausted', {
          'stopReason': 'private text',
        }).stopReason,
        isNull,
      );
    },
  );
  testWidgets(
    'restart reads budget stop and safe recent history without capturing or spending',
    (tester) async {
      final b = StatusBackend();
      final h = H(tester, backend: b);
      final c = h.c;
      addTearDown(c.dispose);
      c.setAvailable(true);
      final reading = c.refreshStatus();
      expect(c.canRequest, isFalse);
      b.status.complete(
        SceneAccountStatus.fromMap({
          'stopReason': 'budget-reserve',
          'limits': {
            'count': 16,
            'maxRequests': 50,
            'spentMicroUsd': 7861,
            'budgetMicroUsd': 10000,
            'windowRemaining': 34,
            'expiresAtMs': 0,
          },
          'recentResults': [
            {
              'requestId': 'a' * 32,
              'status': 'rejected',
              'rejectionReason': 'answer-format',
              'rejectionDetail': 'observation-category',
              'text': 'private description',
              'observations': ['private'],
              'metrics': {
                'modelMs': 1500,
                'usage': {
                  'prompt_tokens': 400,
                  'completion_tokens': 100,
                  'total_tokens': 500,
                },
                'estimate': {'usd': 0.00024, 'notBillingCap': true},
              },
            },
            {'requestId': 'private description', 'status': 'private'},
          ],
        }),
      );
      await reading;
      expect(b.reads, 1);
      expect(b.modes, isEmpty);
      expect(c.attempts, 0);
      expect(c.restricted, isTrue);
      expect(c.status, contains('0.002139'));
      expect(c.stopReason, 'budget-reserve');
      expect(c.diagnostics, contains('observation-category'));
      expect(c.diagnostics, isNot(contains('private')));
      expect(c.serverLimits!.count, 16);
      expect(c.canRequest, isFalse);
      await h.frames(2, rate: 2.0);
      expect(c.status, contains('0.002139'));
      c.observe(null, sourceIssue: 'motion-stale');
      expect(c.status, contains('0.002139'));
      await tester.pump(const Duration(seconds: 2));
      expect(c.status, contains('0.002139'));
      c.setAutomatic(false);
      expect(c.status, contains('0.002139'));
      c.preparationFailed('timeout');
      expect(c.status, contains('0.002139'));
    },
  );
  testWidgets(
    'quota failure delivers exact budget reason instead of unknown paid outcome',
    (tester) async {
      final h = H(tester);
      addTearDown(h.c.dispose);
      h.c.setAutomatic(true);
      await h.frames(5);
      h.b.pending.last.completeError(
        SceneFailure.fromBackend('resource-exhausted', {
          'beforeProvider': true,
          'stopReason': 'budget-reserve',
          'limits': {
            'count': 16,
            'maxRequests': 50,
            'spentMicroUsd': 7861,
            'budgetMicroUsd': 10000,
            'windowRemaining': 34,
            'expiresAtMs': 0,
          },
        }),
      );
      await tester.pump();
      expect(h.c.usageUnknown, isFalse);
      expect(h.c.modeState, SceneModeState.restricted);
      expect(h.c.status, contains('0.002139'));
      expect(h.c.diagnostics, contains('停止原因：budget-reserve'));
      await h.frames(40);
      expect(h.b.modes.length, 1);
      h.c.dispose();
    },
  );
  testWidgets(
    'read-only status failure never becomes an unknown paid request',
    (tester) async {
      final b = StatusBackend(), h = H(tester, backend: b);
      addTearDown(h.c.dispose);
      final reading = h.c.refreshStatus();
      b.status.completeError(StateError('private transport detail'));
      await reading;
      expect(h.c.usageUnknown, isFalse);
      expect(h.c.attempts, 0);
      expect(h.c.diagnostics, isNot(contains('private')));
      expect(b.modes, isEmpty);
      h.c.dispose();
    },
  );

  testWidgets(
    'known quota ceiling blocks new photos while the last valid sentence finishes',
    (tester) async {
      final h = H(tester);
      addTearDown(h.c.dispose);
      h.v.hold = true;
      h.c.setAutomatic(true);
      await h.frames(5);
      h.b.finish(
        limits: {
          'count': 8,
          'maxRequests': 50,
          'spentMicroUsd': 3723,
          'budgetMicroUsd': 10000,
          'windowRemaining': 0,
          'expiresAtMs': h.now
              .add(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
        },
      );
      await tester.pump();
      expect(h.c.serverLimits!.maxRequests, 50);
      expect(h.c.canRequest, isFalse);
      await h.frames(25, contrast: 85);
      expect(h.b.modes.length, 1);
      expect(h.c.speaking, isTrue);
      h.v.wait!.complete();
      await tester.pump();
      await h.frame(contrast: 85);
      expect(h.c.modeState, SceneModeState.restricted);
      expect(h.c.notice, isNotNull);
      expect(h.b.modes.length, 1);
      h.c.dispose();
    },
  );
  test('v2 accepts one update sentence with validated facts; legacy still requires overview grammar', () {
    expect(() => validateSceneText(update), throwsA(isA<SceneFailure>()));
    expect(validateSceneText(update, minSentences: 1, maxSentences: 1), update);
    expect(
      SceneObservation.parseList([table]).single.semanticKey,
      SceneObservation.parseList([
        {...table, 'detail': '左邊木桌'},
      ]).single.semanticKey,
    );
    for (final bad in [
      [
        {...table, 'detail': '請向左行'},
      ],
      [table, table],
      [
        {...table, 'category': 'url'},
      ],
    ]) {
      expect(
        () => SceneObservation.parseList(bad),
        throwsA(isA<SceneFailure>()),
      );
    }
  });
  testWidgets(
    'overview then one-sentence semantic update; exposure changes do not poll cloud',
    (tester) async {
      final h = H(tester);
      addTearDown(h.c.dispose);
      h.c.setAutomatic(true);
      await h.frames(5);
      expect(h.b.modes, ['overview']);
      h.b.finish();
      await tester.pump();
      expect(h.v.said, [overview]);
      await h.frames(35, shift: 20);
      expect(h.b.modes.length, 1);
      await h.frames(5, contrast: 120);
      expect(h.b.modes, ['overview', 'update']);
      h.b.finish(facts: [door]);
      await tester.pump();
      expect(h.v.said, [overview, update]);
      expect(h.c.automatic, isTrue);
      expect(h.c.diagnostics, isNot(contains('木枱')));
      h.c.dispose();
    },
  );
  testWidgets(
    'candidate visual change with equivalent facts is not narrated again',
    (tester) async {
      final h = H(tester);
      addTearDown(h.c.dispose);
      h.c.setAutomatic(true);
      await h.frames(5);
      h.b.finish();
      await tester.pump();
      await h.frames(25, contrast: 85);
      expect(h.b.modes.length, 2);
      h.b.finish(
        facts: [
          {...table, 'detail': '一張木桌'},
        ],
      );
      await tester.pump();
      expect(h.v.said, [overview]);
      expect(h.c.status, contains('未有值得補充'));
      await h.frames(35, contrast: 85);
      expect(h.b.modes.length, 2);
      h.c.dispose();
    },
  );
  testWidgets('ordinary walking drift does not discard a valid paid overview', (
    tester,
  ) async {
    final h = H(tester);
    addTearDown(h.c.dispose);
    h.c.setAutomatic(true);
    await h.frames(5);
    await h.frames(2, yaw: 8, rate: 0.5);
    await h.frames(2, yaw: 17, rate: 0.5);
    h.b.finish();
    await tester.pump();
    expect(h.v.said, [overview]);
    expect(h.c.backendStatus, '成功');
    expect(h.c.text, overview);
    h.c.dispose();
  });
  testWidgets(
    'turn fences old success but mode continues with a fresh first overview',
    (tester) async {
      final h = H(tester);
      addTearDown(h.c.dispose);
      h.c.setAutomatic(true);
      await h.frames(5);
      await h.frames(2, yaw: 45, rate: 2);
      h.b.finish();
      await tester.pump();
      expect(h.v.said, isEmpty);
      expect(h.c.automatic, isTrue);
      await h.frames(25, yaw: 45);
      expect(h.b.modes, ['overview', 'overview']);
      h.b.finish(facts: [door]);
      await tester.pump();
      expect(h.v.said, [overview]);
      h.c.dispose();
    },
  );
  testWidgets(
    'only confirmed unsent transient failures get two bounded retries',
    (tester) async {
      final h = H(tester);
      addTearDown(h.c.dispose);
      h.c.setAutomatic(true);
      await h.frames(5);
      for (var i = 0; i < 3; i++) {
        expect(h.b.modes.length, i + 1);
        h.b.pending.last.completeError(
          const SceneFailure('unavailable', beforeProvider: true),
        );
        await tester.pump();
        if (i < 2) await h.frames(25);
      }
      expect(h.c.automatic, isTrue);
      expect(h.c.restricted, isTrue);
      expect(h.c.usageUnknown, isFalse);
      await h.frames(40);
      expect(h.b.modes.length, 3);
      h.c.dispose();
    },
  );
  testWidgets(
    'uncertain paid outcome retains mode intent but blocks all further requests',
    (tester) async {
      final h = H(tester);
      addTearDown(h.c.dispose);
      h.c.setAutomatic(true);
      await h.frames(5);
      h.b.pending.last.completeError(const SceneFailure('unavailable'));
      await tester.pump();
      expect(h.c.modeState, SceneModeState.restricted);
      expect(h.c.automatic, isTrue);
      expect(h.c.usageUnknown, isTrue);
      await h.frames(40, yaw: 45, contrast: 120);
      expect(h.b.modes.length, 1);
      h.c.dispose();
    },
  );
  testWidgets(
    'explicit stop clears context, does not auto-resume, and next entry starts overview',
    (tester) async {
      final h = H(tester);
      addTearDown(h.c.dispose);
      h.c.setAutomatic(true);
      await h.frames(5);
      h.b.finish();
      await tester.pump();
      h.c.interrupt();
      await h.frames(25, contrast: 120);
      expect(h.b.modes.length, 1);
      h.c.setAutomatic(true);
      await h.frames(5, contrast: 120);
      expect(h.b.modes.last, 'overview');
      h.b.finish();
      await tester.pump();
      expect(h.c.diagnostics, contains('脈絡觀察項目：1'));
      h.c.dispose();
    },
  );
}
