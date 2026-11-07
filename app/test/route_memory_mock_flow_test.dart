import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/route_memory_contract.dart';
import 'package:pathguide/route_memory/route_memory_mock_fixtures.dart';
import 'package:pathguide/route_memory/route_memory_mock_page.dart';
import 'package:pathguide/settings/app_settings.dart';

Widget page(RouteMemoryController c, AppLanguage lang) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: Scaffold(
    body: RouteMemoryMockPage(
      controller: c,
      settings: AppSettings.memory(language: lang),
      onBack: () {},
    ),
  ),
);

Future<void> tap(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  if (key != 'route-back' && key != 'route-stop') await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

void replay(RouteMemoryController c) {
  c.selectRoute(c.routes.single.id);
  c.confirmStart(true);
  c.confirmDirection(true);
  c.startReplay();
}

void main() {
  late RouteMemoryController c;
  setUp(() {
    c = RouteMemoryController();
    c.startRecording();
    for (final n in mockRouteLandmarks) {
      c.recordLandmark(n);
    }
    c.finishRecording();
    c.saveRoute('Mock route');
  });
  tearDown(() => c.dispose());

  for (final key in [
    'route-unknown',
    'route-ambiguous',
    'route-wrong-direction',
  ]) {
    testWidgets(
      '$key withdraws repeated direction and needs both confirmations',
      (t) async {
        replay(c);
        await t.pumpWidget(page(c, AppLanguage.english));
        await tap(t, 'route-read');
        expect(find.textContaining('Mock next landmark'), findsWidgets);
        final old = c.beginObservation()!;
        await tap(t, key);
        expect(find.textContaining('Mock next landmark'), findsNothing);
        expect(find.byKey(const ValueKey('route-readback')), findsNothing);
        await tap(t, 'route-reconfirm');
        expect(c.startConfirmed, isFalse);
        expect(c.directionConfirmed, isFalse);
        c.acceptObservation(old, MockMatch.matched, nodeId: 'mock-corner');
        expect(c.nextLandmark, isNull);
        await t.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('background and old delete dialog cannot resume or delete', (
    t,
  ) async {
    replay(c);
    await t.pumpWidget(page(c, AppLanguage.english));
    await tap(t, 'route-delete');
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(c.phase, RoutePhase.pausedReplay);
    expect(c.nextLandmark, isNull);
    await tap(t, 'route-confirm-delete');
    expect(c.routes.length, 1);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('delete callback after page disposal leaves memory intact', (
    t,
  ) async {
    final nav = GlobalKey<NavigatorState>();
    final visible = ValueNotifier(true);
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, show, child) => show
                ? RouteMemoryMockPage(
                    controller: c,
                    settings: AppSettings.memory(),
                    onBack: () {},
                  )
                : const SizedBox(),
          ),
        ),
      ),
    );
    await tap(t, 'route-delete');
    visible.value = false;
    await t.pump();
    nav.currentState!.pop(true);
    await t.pumpAndSettle();
    expect(c.routes.length, 1);
    await t.pumpWidget(const SizedBox());
    visible.dispose();
  });

  for (final lang in AppLanguage.values) {
    testWidgets('${lang.name} 320x568 scale2 fixed controls and semantics', (
      t,
    ) async {
      t.view.physicalSize = const Size(320, 568);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final handle = t.ensureSemantics();
      try {
        await t.pumpWidget(page(c, lang));
        await t.pumpAndSettle();
        expect(
          MediaQuery.textScalerOf(t.element(find.byType(RouteMemoryMockPage)))
              .scale(1),
          2,
        );
        final label = lang == AppLanguage.english
            ? 'Mock flow: no photos, no location; routes only last until App closes'
            : '樣例模擬流程：無照片、無定位，路線只在 App 關閉前存在';
        expect(find.bySemanticsLabel(label), findsOneWidget);
        for (final k in ['route-back', 'route-stop']) {
          expect(find.byKey(ValueKey(k)).hitTestable(), findsOneWidget);
          expect(
            t.getSize(find.byKey(ValueKey(k))).height,
            greaterThanOrEqualTo(48),
          );
        }
        await t.drag(
          find.byKey(const ValueKey('route-content')),
          const Offset(0, -600),
        );
        await t.pumpAndSettle();
        for (final k in ['route-back', 'route-stop']) {
          expect(find.byKey(ValueKey(k)).hitTestable(), findsOneWidget);
        }
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      } finally {
        handle.dispose();
      }
    });
  }
}
