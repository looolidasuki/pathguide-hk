import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/main.dart';
import 'package:pathguide/route_memory/route_memory_contract.dart';
import 'package:pathguide/route_memory/route_memory_mock_fixtures.dart';
import 'package:pathguide/route_memory/route_memory_mock_page.dart';
import 'package:pathguide/settings/app_settings.dart';

void main() {
  for (final language in AppLanguage.values) {
    testWidgets(
      '${language.name}: developer entry preserves mock routes across leave and section switches without hardware',
      (t) async {
        t.view.physicalSize = const Size(320, 568);
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final calls = <String>[];
        const channels = [
          'hk.pathguide/vision',
          'hk.pathguide/depth',
          'hk.pathguide/navigation',
          'hk.pathguide/menu',
          'flutter_tts',
          'plugins.it_nomads.com/flutter_secure_storage',
        ];
        for (final name in channels) {
          messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
            calls.add('$name:${call.method}');
            return null;
          });
        }
        addTearDown(() {
          for (final name in channels) {
            messenger.setMockMethodCallHandler(MethodChannel(name), null);
          }
        });
        await t.pumpWidget(
          PathGuideApp(settings: AppSettings.memory(language: language)),
        );
        await t.pumpAndSettle();
        String tr(String zh, String en) =>
            language == AppLanguage.chinese ? zh : en;
        Future<void> open() async {
          if (find.byKey(const ValueKey('task-home')).evaluate().isNotEmpty) {
            await t.scrollUntilVisible(
              find.text(tr('設定與使用教學', 'Settings and help')),
              150,
            );
            await t.ensureVisible(
              find.widgetWithText(
                OutlinedButton,
                tr('設定與使用教學', 'Settings and help'),
              ),
            );
            await t.pumpAndSettle();
            await t.tap(
              find.widgetWithText(
                OutlinedButton,
                tr('設定與使用教學', 'Settings and help'),
              ),
            );
            await t.pumpAndSettle();
          }
          if (find
              .byKey(const ValueKey('settings-page'))
              .evaluate()
              .isNotEmpty) {
            await t.scrollUntilVisible(
              find.text(tr('開發測試', 'Developer testing')),
              150,
            );
            await t.ensureVisible(
              find.widgetWithText(
                OutlinedButton,
                tr('開發測試', 'Developer testing'),
              ),
            );
            await t.pumpAndSettle();
            await t.tap(
              find.widgetWithText(
                OutlinedButton,
                tr('開發測試', 'Developer testing'),
              ),
            );
            await t.pumpAndSettle();
          }
          final entry = find.ancestor(
            of: find.text(
              language == AppLanguage.chinese
                  ? '室內路線工具（試驗）'
                  : 'Indoor route tools (trial)',
            ),
            matching: find.byType(OutlinedButton),
          );
          await t.scrollUntilVisible(
            entry,
            150,
            scrollable: find.byType(Scrollable).first,
          );
          await t.pumpAndSettle();
          await t.tap(entry);
          await t.pumpAndSettle();
          final skip = find.text(tr('略過說明', 'Skip introduction'));
          if (skip.evaluate().isNotEmpty) {
            await t.ensureVisible(skip);
            await t.tap(skip);
            await t.pumpAndSettle();
          }
        }

        await open();
        final c = t
            .widget<RouteMemoryMockPage>(find.byType(RouteMemoryMockPage))
            .controller;
        c.startRecording();
        for (final n in mockRouteLandmarks) {
          c.recordLandmark(n);
        }
        c.finishRecording();
        await t.pumpAndSettle();
        t.view.viewInsets = const FakeViewPadding(bottom: 280);
        addTearDown(t.view.resetViewInsets);
        await t.pumpAndSettle();
        for (final k in ['route-back', 'route-stop']) {
          expect(find.byKey(ValueKey(k)).hitTestable(), findsOneWidget);
        }
        expect(t.takeException(), isNull);
        t.view.resetViewInsets();
        await t.pumpAndSettle();
        c.saveRoute('My route');
        c.selectRoute(c.routes.single.id);
        c.confirmStart(true);
        c.confirmDirection(true);
        c.startReplay();
        final old = c.beginObservation()!;
        await t.pump();
        await t.tap(find.byKey(const ValueKey('route-back')));
        await t.pumpAndSettle();
        expect(c.phase, RoutePhase.pausedReplay);
        c.acceptObservation(old, MockMatch.matched, nodeId: 'mock-corner');
        expect(c.nextLandmark, isNull);
        await open();
        expect(
          t
              .widget<RouteMemoryMockPage>(find.byType(RouteMemoryMockPage))
              .controller,
          same(c),
        );
        expect(c.routes.single.name, 'My route');
        await t.tap(find.byKey(const ValueKey('route-back')));
        await t.pumpAndSettle();
        expect(find.byType(RouteMemoryMockPage), findsNothing);
        await open();
        expect(c.phase, RoutePhase.pausedReplay);
        expect(calls, isEmpty);
        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();
      },
    );
  }
}
