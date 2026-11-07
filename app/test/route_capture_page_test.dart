import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/route_capture_controller.dart';
import 'package:pathguide/route_memory/route_capture_page.dart';
import 'package:pathguide/route_memory/route_observation_source.dart';
import 'package:pathguide/settings/app_settings.dart';

import 'route_camera_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const reviewDir = String.fromEnvironment('ROUTE_REVIEW_DIR');
  setUpAll(() async {
    if (reviewDir.isNotEmpty) {
      final font = await File(
        '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
      ).readAsBytes();
      await (FontLoader(
        'ReviewSans',
      )..addFont(Future.value(ByteData.sublistView(font)))).load();
    }
  });
  testWidgets('stop removes the captured photo from the image cache', (
    t,
  ) async {
    final native = RouteNativeFixture()..attach();
    final c = RouteCaptureController(
      source: RouteObservationSource(supported: true),
    );
    await t.pumpWidget(
      MaterialApp(
        home: RouteCapturePage(
          controller: c,
          settings: AppSettings.memory(),
          onBack: () {},
          previewBuilder: (_) => const SizedBox(height: 200),
        ),
      ),
    );
    await c.start();
    await t.pumpAndSettle();
    await t.runAsync(() => c.capture());
    await t.pumpAndSettle();
    final provider = MemoryImage(c.keyframe!.bytes);
    await t.runAsync(
      () => precacheImage(provider, t.element(find.byType(RouteCapturePage))),
    );
    await t.pumpAndSettle();
    expect(
      PaintingBinding.instance.imageCache.statusForKey(provider).untracked,
      isFalse,
    );
    await t.tap(find.byKey(const ValueKey('capture-stop')));
    await t.pumpAndSettle();
    expect(
      PaintingBinding.instance.imageCache.statusForKey(provider).untracked,
      isTrue,
    );
    await t.pumpWidget(const SizedBox());
    c.dispose();
    await t.pump();
    native.detach();
  });
  testWidgets(
    'unsupported platform explains the limit without opening a camera',
    (t) async {
      final c = RouteCaptureController(
        source: RouteObservationSource(supported: false),
      );
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: reviewDir.isEmpty ? null : 'ReviewSans'),
          home: RouteCapturePage(
            controller: c,
            settings: AppSettings.memory(language: AppLanguage.english),
            onBack: () {},
          ),
        ),
      );
      expect(find.textContaining('not supported'), findsOneWidget);
      expect(c.canStart, isFalse);
      expect(find.byType(UiKitView), findsNothing);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  for (final language in AppLanguage.values) {
    testWidgets(
      'permission, keyboard and lifecycle controls at 2x text: $language',
      (t) async {
        t.view.physicalSize = const Size(320, 568);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final native = RouteNativeFixture()..delayStart = true;
        native.attach();
        final c = RouteCaptureController(
          source: RouteObservationSource(supported: true),
        );
        final repaint = GlobalKey();
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              fontFamily: reviewDir.isEmpty ? null : 'ReviewSans',
            ),
            home: RepaintBoundary(
              key: repaint,
              child: MediaQuery(
                data: const MediaQueryData(
                  size: Size(320, 568),
                  textScaler: TextScaler.linear(2),
                  viewInsets: EdgeInsets.only(bottom: 180),
                ),
                child: RouteCapturePage(
                  controller: c,
                  settings: AppSettings.memory(language: language),
                  onBack: () {},
                  previewBuilder: (_) =>
                      const ColoredBox(color: Colors.black54),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.byKey(const ValueKey('capture-primary')));
        await t.pump();
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await t.pump();
        expect(c.status, RouteCaptureStatus.starting);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        native.startReply!.complete({
          ...native.current!,
          'status': 'permission',
        });
        await t.pumpAndSettle();
        expect(c.status, RouteCaptureStatus.permission);
        expect(c.canStart, isTrue);
        await t.ensureVisible(find.byKey(const ValueKey('capture-status')));
        await t.pumpAndSettle();
        if (reviewDir.isNotEmpty) {
          final boundary =
              repaint.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await t.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File('$reviewDir/capture-${language.name}-2x-keyboard.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await t.pump();
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await t.pumpAndSettle();
        expect(c.running, isFalse);
        expect(c.status, RouteCaptureStatus.paused);
        expect(t.takeException(), isNull);
        await t.tap(find.byKey(const ValueKey('capture-stop')));
        await t.pumpAndSettle();
        await t.pumpWidget(const SizedBox());
        c.dispose();
        await t.pump();
        native.detach();
      },
    );
  }
  testWidgets(
    'small screen at two-times text keeps start, stop and back usable',
    (t) async {
      t.view.physicalSize = const Size(320, 568);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final native = RouteNativeFixture()..attach();
      final controller = RouteCaptureController(
        source: RouteObservationSource(supported: true),
      );
      var back = false;
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: reviewDir.isEmpty ? null : 'ReviewSans'),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 568),
              textScaler: TextScaler.linear(2),
            ),
            child: RouteCapturePage(
              controller: controller,
              settings: AppSettings.memory(language: AppLanguage.english),
              onBack: () => back = true,
              previewBuilder: (_) =>
                  const SizedBox(key: ValueKey('native-preview'), height: 200),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('capture-primary')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('native-preview')), findsOneWidget);
      expect(controller.running, isTrue);
      await t.tap(find.byKey(const ValueKey('capture-stop')));
      await t.pumpAndSettle();
      expect(controller.running, isFalse);
      expect(controller.keyframe, isNull);
      await t.tap(find.byKey(const ValueKey('capture-back')));
      await t.pumpAndSettle();
      expect(back, isTrue);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      controller.dispose();
      await t.pump();
      native.detach();
    },
  );
}
