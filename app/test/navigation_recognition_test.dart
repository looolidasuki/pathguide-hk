import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/navigation/navigation_controller.dart';
import 'package:pathguide/navigation/navigation_page.dart';
import 'package:pathguide/settings/app_settings.dart';
import 'package:pathguide/vision/detection.dart';
import 'package:pathguide/vision/vision_source.dart';

import 'navigation_test.dart' as fixture;
import 'recognition_session_test.dart' as vision;

void main() {
  testWidgets('navigation owns one camera; pause and background release it', (
    tester,
  ) async {
    final services = fixture.Services();
    final nav = NavigationController(
      searchService: services,
      routeService: services,
      location: services,
      store: fixture.MemoryStore(),
      clock: () => services.now,
    );
    await nav.select(fixture.place());
    await nav.start();
    final speaker = fixture.RecordingNavigationSpeaker();
    final cameras = <vision.Camera>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NavigationPage(
            settings: AppSettings.memory(),
            controller: nav,
            speech: fixture.SilentSpeech(),
            speaker: speaker,
            mapBuilder: (_, _) => const SizedBox(height: 50),
            visionFactory: () {
              final camera = vision.Camera();
              camera.ready.complete(
                const VisionSourceStatus(ok: true, message: 'ready'),
              );
              cameras.add(camera);
              return camera;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(cameras, isEmpty);
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(cameras.length, 1);
    cameras.single.events.add(
      const VisionFrame(
        detections: [
          Detection(id: 7, score: .95, cx: .5, cy: .5, w: .2, h: .2),
        ],
        inferenceMs: 2,
        frameWidth: 100,
        frameHeight: 100,
      ),
    );
    await tester.pumpAndSettle();
    expect(speaker.words, contains('垃圾桶'));
    await tester.tap(find.text('重播下一步'));
    await tester.pumpAndSettle();
    expect(speaker.words.last, contains('距離下一步'));
    await tester.runAsync(() async {
      await nav.pause();
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    expect(cameras.single.disposed, 1);
    await tester.runAsync(() async {
      await nav.start();
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(cameras.length, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(cameras.last.disposed, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(cameras.length, 2); // Navigation must be explicitly resumed.
    await tester.pumpWidget(const SizedBox());
    for (final camera in cameras) {
      await camera.events.close();
    }
  });
}
