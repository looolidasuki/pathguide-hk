import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/navigation/navigation_controller.dart';
import 'package:pathguide/navigation/navigation_models.dart';
import 'package:pathguide/navigation/navigation_page.dart';
import 'package:pathguide/settings/app_settings.dart';

import 'navigation_test.dart' as fixture;

NavigationController controller(fixture.Services services) =>
    NavigationController(
      searchService: services,
      routeService: services,
      location: services,
      store: fixture.MemoryStore(),
      clock: () => services.now,
    );

Widget page(
  NavigationController nav,
  fixture.RecordingNavigationSpeaker speaker, {
  double textScale = 1,
}) => MaterialApp(
  home: Scaffold(
    bottomNavigationBar: const SizedBox(height: 80),
    body: MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 844),
        textScaler: TextScaler.linear(textScale),
      ),
      child: NavigationPage(
        settings: AppSettings.memory(),
        controller: nav,
        speech: fixture.SilentSpeech(),
        speaker: speaker,
        mapBuilder: (_, _) => const SizedBox(height: 800, child: Text('路線地圖')),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'large text keeps navigation controls visible while content scrolls',
    (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final services = fixture.Services();
      final nav = controller(services);
      final speaker = fixture.RecordingNavigationSpeaker();
      await nav.select(fixture.place());
      await nav.start();
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: page(nav, speaker, textScale: 2),
        ),
      );
      await tester.pumpAndSettle();
      final controls = find.byKey(const ValueKey('navigation-controls'));
      final before = tester.getRect(controls);
      for (final name in ['重播下一步', '目前位置', '暫停導航', '結束導航']) {
        expect(find.text(name).hitTestable(), findsOneWidget);
        expect(find.bySemanticsLabel(name), findsOneWidget);
        expect(
          tester.getSize(find.widgetWithText(OutlinedButton, name)).height,
          greaterThanOrEqualTo(48),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.drag(
        find.byKey(const ValueKey('navigation-home')),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(controls), before);
      await tester.tap(find.text('重播下一步'));
      await tester.pumpAndSettle();
      expect(speaker.words.last, contains('距離下一步'));

      const captureDir = String.fromEnvironment('NAVIGATION_TEST_CAPTURE_DIR');
      if (captureDir.isNotEmpty) {
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(captureDir).create(recursive: true);
          await File('$captureDir/navigation-active-2x.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      // Stream cancellation can complete outside the widget test's fake clock.
      await tester.runAsync(() async {
        await tester.tap(find.text('暫停導航'));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(nav.state, NavigationState.paused);
      expect(services.awake, false);
      expect(find.text('繼續導航').hitTestable(), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('繼續導航'));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(nav.state, NavigationState.navigating);
      await tester.tap(find.text('結束導航'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '繼續導航'))
            .autofocus,
        true,
      );
      await tester.tap(find.text('繼續導航'));
      await tester.pumpAndSettle();
      expect(nav.state, NavigationState.navigating);
      await tester.tap(find.text('結束導航'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('確認結束'));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(nav.state, NavigationState.idle);
      expect(services.awake, false);
      expect(find.byKey(const ValueKey('navigation-controls')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await services.stream.close();
      semantics.dispose();
    },
  );

  testWidgets('location retry returns to preview before starting navigation', (
    tester,
  ) async {
    final services = fixture.Services()..nextFix = fixture.fix(0, accuracy: 80);
    final nav = controller(services);
    await nav.select(fixture.place());
    await tester.pumpWidget(page(nav, fixture.RecordingNavigationSpeaker()));
    await tester.pumpAndSettle();
    expect(find.text('開始導航'), findsNothing);
    await tester.ensureVisible(find.text('重新取得路線'));
    services.nextFix = fixture.fix(0);
    await tester.tap(find.text('重新取得路線'));
    await tester.pumpAndSettle();
    expect(nav.state, NavigationState.preview);
    expect(services.starts, 0);
    await tester.scrollUntilVisible(
      find.text('開始導航'),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('navigation-home')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('開始導航'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await services.stream.close();
  });

  testWidgets('submitting a search dismisses the destination keyboard', (
    tester,
  ) async {
    final services = fixture.Services();
    final nav = controller(services);
    await tester.pumpWidget(page(nav, fixture.RecordingNavigationSpeaker()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '測試目的地');
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      true,
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      false,
    );
    expect(find.widgetWithText(ListTile, '測試目的地'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await services.stream.close();
  });

  test(
    'an address reply after pause cannot describe an old position',
    () async {
      final services = DelayedAddressServices();
      final nav = controller(services);
      await nav.select(fixture.place());
      await nav.start();
      final response = nav.currentPosition();
      await nav.pause();
      services.addressReply.complete('舊地址');
      expect(await response, isNot(contains('舊地址')));
      nav.dispose();
      await services.stream.close();
    },
  );
}

class DelayedAddressServices extends fixture.Services {
  final addressReply = Completer<String?>();
  @override
  Future<String?> address(Coordinate coordinate) => addressReply.future;
}
