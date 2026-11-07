import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/route_capture_controller.dart';
import 'package:pathguide/route_memory/route_observation_source.dart';

import 'route_camera_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'captured photo is cleared by stop and an explicit restart is available',
    () async {
      final native = RouteNativeFixture()..attach();
      final c = RouteCaptureController(
        source: RouteObservationSource(supported: true),
      );
      await c.start();
      await Future<void>.delayed(Duration.zero);
      expect(c.canCapture, isTrue);
      await c.capture();
      expect(c.status, RouteCaptureStatus.captured);
      expect(c.keyframe, isNotNull);
      await c.stop();
      expect(c.keyframe, isNull);
      expect(c.status, RouteCaptureStatus.stopped);
      expect(c.canStart, isTrue);
      c.dispose();
      await Future<void>.delayed(Duration.zero);
      native.detach();
    },
  );

  test(
    'camera handoff event withdraws photo and requires explicit restart',
    () async {
      final native = RouteNativeFixture()..attach();
      final c = RouteCaptureController(
        source: RouteObservationSource(supported: true),
      );
      await c.start();
      await Future<void>.delayed(Duration.zero);
      await c.capture();
      native.sendEvent('paused');
      await Future<void>.delayed(Duration.zero);
      expect(c.running, isFalse);
      expect(c.keyframe, isNull);
      expect(c.status, RouteCaptureStatus.paused);
      c.dispose();
      await Future<void>.delayed(Duration.zero);
      native.detach();
    },
  );

  test('unconfirmed stop is shown without claiming camera stopped', () async {
    final native = RouteNativeFixture()..attach();
    final c = RouteCaptureController(
      source: RouteObservationSource(supported: true),
    );
    await c.start();
    await Future<void>.delayed(Duration.zero);
    native.stopStatus = 'stop_unconfirmed';
    await c.stop();
    expect(c.status, RouteCaptureStatus.stopUnconfirmed);
    expect(c.running, isFalse);
    expect(c.keyframe, isNull);
    await c.stop();
    expect(c.status, RouteCaptureStatus.stopUnconfirmed);
    native.stopStatus = 'stopped';
    await c.stop();
    expect(c.status, RouteCaptureStatus.stopped);
    c.dispose();
    await Future<void>.delayed(Duration.zero);
    native.detach();
  });
  test('stop during permission wait ignores late start and foreground never resumes', () async {
    final native = RouteNativeFixture()..delayStart = true;
    native.attach();
    final controller = RouteCaptureController(
      source: RouteObservationSource(supported: true),
    );
    await controller.start();
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, RouteCaptureStatus.starting);
    controller.setForeground(false);
    await Future<void>.delayed(Duration.zero);
    expect(controller.running, isFalse);
    native.startReply!.complete({...native.current!, 'status': 'running'});
    await Future<void>.delayed(Duration.zero);
    controller.setForeground(true);
    expect(controller.running, isFalse);
    expect(controller.status, RouteCaptureStatus.paused);
    expect(controller.canStart, isTrue);
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    native.detach();
  });
}
