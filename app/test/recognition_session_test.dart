import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/tts/announcer.dart';
import 'package:pathguide/vision/recognition_session.dart';
import 'package:pathguide/vision/vision_source.dart';

class Camera implements VisionSource {
  final ready = Completer<VisionSourceStatus>();
  final events = StreamController<VisionFrame>.broadcast();
  int disposed = 0;
  @override
  String get displayName => 'test camera';
  @override
  Size get frameSize => const Size(100, 100);
  @override
  int get rotationDegrees => 0;
  @override
  double threshold = .3;
  @override
  Stream<VisionFrame> get frames => events.stream;
  @override
  Future<VisionSourceStatus> initialize() => ready.future;
  @override
  Future<VisionDiagnostics?> diagnostics() async => null;
  @override
  Future<void> dispose() async {
    disposed++;
  }
}

void main() {
  test(
    'late camera permission after stop cannot restart or retain frames',
    () async {
      final camera = Camera();
      final session = RecognitionSession(
        createSource: () => camera,
        announcer: Announcer(speaker: NullSpeaker()),
      );
      final start = session.setRunning(true);
      await Future<void>.delayed(Duration.zero);
      final stop = session.setRunning(false);
      camera.ready.complete(
        const VisionSourceStatus(ok: true, message: 'ready'),
      );
      await start;
      await stop;
      camera.events.add(
        const VisionFrame(
          detections: [],
          inferenceMs: 2,
          frameWidth: 100,
          frameHeight: 100,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(session.ready, false);
      expect(session.frame, isNull);
      expect(camera.disposed, 1);
      session.dispose();
      await camera.events.close();
    },
  );
  test('disposal during initialization releases the source after permission returns', () async {
    final camera = Camera();
    final session = RecognitionSession(
      createSource: () => camera,
      announcer: Announcer(speaker: NullSpeaker()),
    );
    final start = session.setRunning(true);
    await Future<void>.delayed(Duration.zero);
    session.dispose();
    camera.ready.complete(const VisionSourceStatus(ok: true, message: 'late'));
    await start;
    await Future<void>.delayed(Duration.zero);
    expect(camera.disposed, 1);
    await camera.events.close();
  });
  test(
    'a closed camera stream clears the current result and speech eligibility',
    () async {
      final camera = Camera();
      camera.ready.complete(
        const VisionSourceStatus(ok: true, message: 'ready'),
      );
      final announcer = Announcer(speaker: NullSpeaker());
      final session = RecognitionSession(
        createSource: () => camera,
        announcer: announcer,
      );
      await session.setRunning(true);
      camera.events.add(
        const VisionFrame(
          detections: [],
          inferenceMs: 2,
          frameWidth: 100,
          frameHeight: 100,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(session.frame, isNotNull);
      await camera.events.close();
      expect(session.frame, isNull);
      expect(session.ready, isFalse);
      expect(announcer.enabled, isFalse);
      await session.setRunning(false);
      session.dispose();
    },
  );
}
