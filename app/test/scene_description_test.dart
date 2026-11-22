import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/route_observation_source.dart';
import 'package:pathguide/scene/scene_backend.dart';
import 'package:pathguide/scene/scene_controller.dart';
import 'package:pathguide/scene/scene_page.dart';
import 'package:pathguide/settings/app_settings.dart';
import 'package:pathguide/tts/announcer.dart';
import 'package:pathguide/tts/speech_coordinator.dart';

import 'route_camera_fixture.dart';

const good = '畫面左邊有張木枱。中間見到一道門，右邊有張凳。';
Future<void> tick() => Future<void>.delayed(Duration.zero);

class Backend implements SceneBackend {
  int calls = 0;
  String? id;
  Uint8List? bytes;
  Completer<SceneReply> pending = Completer<SceneReply>();
  @override
  Future<SceneReply> describe(
    Uint8List jpeg,
    String requestId, {
    bool Function()? isCurrent,
  }) {
    calls++;
    id = requestId;
    bytes = jpeg;
    return pending.future;
  }

  void finish({bool rejected = false, bool usage = true}) => pending.complete(
    SceneReply.fromMap({
      'requestId': id,
      'status': rejected ? 'rejected' : 'complete',
      if (!rejected) 'text': good,
      'metrics': {
        'modelMs': 52,
        'usage': usage
            ? {
                'prompt_tokens': 100,
                'completion_tokens': 20,
                'total_tokens': 120,
              }
            : null,
        'estimate': null,
      },
    }, id!),
  );
}

class Output implements Speaker {
  List<String> words = [];
  Completer<void>? stopping, playing;
  bool hold = false;
  @override
  Future<void> speak(String text) async {
    words.add(text);
    if (hold) playing = Completer<void>();
    await playing?.future;
  }

  @override
  Future<void> stop() async {
    await stopping?.future;
    if (playing != null && !playing!.isCompleted) playing!.complete();
  }

  @override
  Future<List<String>> languages() async => ['zh-HK'];
}

class WidgetSource extends RouteObservationSource {
  WidgetSource() : super(supported: true);
  @override
  Stream<RouteCaptureStatus> get events => const Stream.empty();
  @override
  Future<RouteCaptureStatus> start({
    required String routeId,
    required int routeVersion,
  }) async => RouteCaptureStatus.running;
  @override
  Future<RouteCaptureResult> capture() async => RouteCaptureResult(
    RouteCaptureStatus.captured,
    RouteKeyframe(Uint8List(1), 1, 1, {}),
  );
  @override
  Future<RouteCaptureStatus> stop() async => RouteCaptureStatus.stopped;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RouteNativeFixture camera;
  late Backend backend;
  late Output output;
  late SpeechCoordinator voice;
  late SceneController c;
  setUp(() {
    camera = RouteNativeFixture()..attach();
    backend = Backend();
    output = Output();
    voice = SpeechCoordinator(output);
    c = SceneController(
      source: RouteObservationSource(supported: true),
      backend: backend,
      voice: voice,
    );
  });
  tearDown(() {
    c.dispose();
    camera.detach();
  });
  Future<void> untilAnalysis() async {
    for (var i = 0; i < 30 && backend.calls == 0; i++) {
      await tick();
    }
    expect(c.status, SceneStatus.analysing);
  }

  test('real native-channel contract to mock cloud to validated speech, separately measured', () async {
    final work = c.describe();
    await untilAnalysis();
    expect(backend.bytes, camera.jpeg);
    expect(output.words, isEmpty);
    expect(c.captureMs, isNotNull);
    backend.finish();
    await work;
    expect(c.status, SceneStatus.complete);
    expect(c.text, good);
    expect(output.words, [good]);
    expect(c.uploadModelMs, isNotNull);
    expect(c.speechStartMs, isNull); // no native start event was observed
    c.speechStarted();
    expect(c.speechStartMs, isNotNull);
    expect(c.metrics!.totalTokens, 120);
  });
  test(
    'camera start waits locally for first frame before one cloud call',
    () async {
      var captures = 0;
      camera.changeCapture = (value) =>
          ++captures < 3 ? {'status': 'no_frame'} : value;
      final work = c.describe();
      for (var i = 0; i < 50 && backend.calls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(captures, 3);
      expect(backend.calls, 1);
      backend.finish();
      await work;
      expect(c.status, SceneStatus.complete);
    },
  );
  test('cancel holds in-flight lock, drops late answer and never queues a second call', () async {
    final work = c.describe();
    await untilAnalysis();
    c.invalidate();
    expect(c.status, SceneStatus.cancelled);
    expect(c.busy, isTrue);
    await c.describe();
    expect(backend.calls, 1);
    backend.finish();
    await work;
    expect(c.text, isNull);
    expect(output.words, isEmpty);
    expect(c.busy, isFalse);
    expect(c.metrics!.totalTokens, 120);
  });
  for (final reason in ['turn', 'journey', 'background', 'exit']) {
    test('$reason invalidates late results and speech', () async {
      final work = c.describe();
      await untilAnalysis();
      if (reason == 'background') {
        c.foreground(false);
      } else if (reason == 'exit') {
        c.dispose();
      } else {
        c.invalidate(reason: reason);
      } // explicit seam, NOT a sensor integration
      backend.finish();
      await work;
      expect(c.text, isNull);
      expect(output.words, isEmpty);
      if (reason == 'exit') {
        c = SceneController(
          source: RouteObservationSource(supported: true),
          backend: backend,
          voice: voice,
        );
      }
    });
  }
  test('cancellation during camera callback prevents even an upload', () async {
    camera.delayCapture = true;
    final work = c.describe();
    for (var i = 0; i < 30 && camera.captureReply == null; i++) {
      await tick();
    }
    expect(camera.captureReply, isNotNull);
    c.invalidate();
    camera.captureReply!.complete(camera.capturedResponse);
    await work;
    expect(backend.calls, 0);
    expect(output.words, isEmpty);
  });
  test(
    'navigation drops scene answer instead of queueing it for later',
    () async {
      final work = c.describe();
      await untilAnalysis();
      output.hold = true;
      final navigation = voice.channel(SpeechChannel.navigation).speak('轉彎提示');
      await tick();
      backend.finish();
      await work;
      expect(c.status, SceneStatus.complete);
      expect(output.words, ['轉彎提示']);
      output.playing!.complete();
      await navigation;
      await tick();
      expect(output.words, ['轉彎提示']);
      expect(c.speechStartMs, isNull);
    },
  );
  test(
    'cancel while validated speech waits for slow stop suppresses that speech',
    () async {
      final work = c.describe();
      await untilAnalysis();
      output.stopping = Completer<void>();
      backend.finish();
      await tick();
      c.invalidate();
      output.stopping!.complete();
      await work;
      await tick();
      expect(output.words, isEmpty);
      expect(c.text, isNull);
    },
  );
  test(
    'failure and rejected/truncated result cannot be displayed or spoken',
    () async {
      final work = c.describe();
      await untilAnalysis();
      backend.finish(rejected: true);
      await work;
      expect(c.status, SceneStatus.failed);
      expect(c.failure, 'rejected');
      expect(c.text, isNull);
      expect(output.words, isEmpty);
      expect(c.metrics!.totalTokens, 120);
      backend.pending = Completer<SceneReply>();
      final second = c.describe();
      await tick();
      await tick();
      await tick();
      backend.pending.completeError(const SceneFailure('deadline-exceeded'));
      await second;
      expect(c.status, SceneStatus.failed);
      expect(c.failure, 'deadline-exceeded');
      expect(output.words, isEmpty);
    },
  );
  test(
    'no frame or unconfirmed camera stop never sends cloud request',
    () async {
      camera.changeCapture = (_) => {'status': 'no_frame'};
      await c.describe();
      expect(backend.calls, 0);
      expect(c.status, SceneStatus.failed);
      camera.changeCapture = null;
      camera.stopStatus = 'stop_unconfirmed';
      await c.describe();
      expect(backend.calls, 0);
      expect(c.failure, 'stopUnconfirmed');
    },
  );
  test('freshness deadline invalidates late cloud response', () async {
    c.dispose();
    c = SceneController(
      source: WidgetSource(),
      backend: backend,
      voice: voice,
      maxAge: const Duration(milliseconds: 100),
    );
    final work = c.describe();
    await untilAnalysis();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    backend.finish();
    await work;
    expect(c.status, SceneStatus.cancelled);
    expect(c.failure, 'expired');
    expect(output.words, isEmpty);
  });
  test(
    'missing usage remains missing; mismatched IDs and unsafe text fail closed',
    () {
      final response = {
        'requestId': 'r',
        'status': 'complete',
        'text': good,
        'metrics': {'modelMs': 20, 'usage': null, 'estimate': null},
      };
      final reply = SceneReply.fromMap(response, 'r');
      expect(reply.metrics.totalTokens, isNull);
      expect(reply.metrics.estimatedUsd, isNull);
      expect(
        () => SceneReply.fromMap(response, 'different'),
        throwsA(isA<SceneFailure>()),
      );
      for (final text in [
        '安全通行。向左行。',
        '前方有門。大約三米。',
        '门在这边。可直接走。',
        '只得一句。',
        '前方有門。靠左行啦。',
        '前方有門。你可行入去。',
        '枱。門。\n凳。',
      ]) {
        expect(() => validateSceneText(text), throwsA(isA<SceneFailure>()));
      }
    },
  );
  testWidgets(
    'attestation failure is distinguished from disabled service and never speaks',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      c.dispose();
      backend = Backend();
      c = SceneController(
        source: WidgetSource(),
        backend: backend,
        voice: SpeechCoordinator(output),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ScenePage(
            settings: AppSettings.memory(),
            controller: c,
            onBack: () {},
          ),
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, '描述前方'));
      await tester.pump();
      await tester.pump();
      expect(backend.calls, 1);
      backend.pending.completeError(
        const SceneFailure('app-check-unavailable'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('手機驗證未完成（App Check）'), findsOneWidget);
      expect(find.textContaining('場景服務未啟用'), findsNothing);
      expect(output.words, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('large text retains fixed describe and cancel controls', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    c.dispose();
    c = SceneController(
      source: WidgetSource(),
      backend: backend,
      voice: SpeechCoordinator(output),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: ScenePage(
            settings: AppSettings.memory(),
            controller: c,
            onBack: () {},
          ),
        ),
      ),
    );
    final button = find.widgetWithText(FilledButton, '描述前方');
    final cancel = find.widgetWithText(OutlinedButton, '取消描述及播音');
    expect(tester.getBottomRight(button).dy, lessThanOrEqualTo(568));
    expect(tester.getBottomRight(cancel).dy, lessThanOrEqualTo(568));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'accessible manual entry shows analysis, cancel and late-result suppression',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      c.dispose();
      voice = SpeechCoordinator(output);
      c = SceneController(
        source: WidgetSource(),
        backend: backend,
        voice: voice,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ScenePage(
            settings: AppSettings.memory(),
            controller: c,
            onBack: () {},
          ),
        ),
      );
      final button = find.widgetWithText(FilledButton, '描述前方');
      await tester.ensureVisible(button);
      expect(c.canDescribe, isTrue, reason: 'foreground manual entry');
      await tester.tap(button);
      await tester.pump();
      await tester.pump();
      expect(backend.calls, 1);
      expect(find.text('正在分析，可隨時取消。'), findsOneWidget);
      final semantics = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('scene-status')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(semantics.properties.liveRegion, isTrue);
      final cancel = find.widgetWithText(OutlinedButton, '取消描述及播音');
      await tester.ensureVisible(cancel);
      await tester.tap(cancel);
      await tester.pump();
      backend.finish();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scene-result')), findsNothing);
      expect(output.words, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
