import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/route_memory_contract.dart';
import 'package:pathguide/route_memory/route_memory_mock_page.dart';
import 'package:pathguide/settings/app_settings.dart';

Widget _page(RouteMemoryController c, AppSettings s, {VoidCallback? onBack}) {
  return MaterialApp(
    home: Scaffold(
      body: RouteMemoryMockPage(
        controller: c,
        settings: s,
        onBack: onBack ?? () {},
      ),
    ),
  );
}

Future<void> tapRoute(WidgetTester t, String key) async {
  final finder = find.byKey(ValueKey(key));
  if (key != 'route-back' && key != 'route-stop') await t.ensureVisible(finder);
  await t.tap(finder);
  await t.pumpAndSettle();
}

void main() {
  late RouteMemoryController c;

  setUp(() => c = RouteMemoryController(clock: () => DateTime(2020)));
  tearDown(() => c.dispose());

  testWidgets('record, save, replay, confirm arrival, delete', (t) async {
    await t.pumpWidget(
      _page(c, AppSettings.memory(language: AppLanguage.english)),
    );
    await tapRoute(t, 'route-start-recording');
    await t.pump();
    for (var i = 0; i < 3; i++) {
      await tapRoute(t, 'route-add-landmark');
      await t.pump();
    }
    expect(c.draft.length, 3);
    await tapRoute(t, 'route-pause');
    await t.pump();
    expect(c.phase, RoutePhase.pausedRecording);
    await tapRoute(t, 'route-resume-recording');
    await t.pump();
    expect(c.phase, RoutePhase.recording);
    await tapRoute(t, 'route-review');
    await t.pump();
    expect(c.phase, RoutePhase.review);
    await t.enterText(find.byKey(const ValueKey('route-name')), 'My route');
    await t.pump();
    await tapRoute(t, 'route-save');
    await t.pump();
    expect(c.phase, RoutePhase.saved);
    expect(c.routes.length, 1);
    final id = c.routes.first.id;
    await tapRoute(t, 'route-select-$id');
    await t.pump();
    expect(c.phase, RoutePhase.confirming);
    expect(c.canStartReplay, isFalse);
    await tapRoute(t, 'route-confirm-start');
    await t.pump();
    expect(c.canStartReplay, isFalse);
    await tapRoute(t, 'route-confirm-direction');
    await t.pump();
    expect(c.canStartReplay, isTrue);
    await tapRoute(t, 'route-start-replay');
    await t.pump();
    expect(c.phase, RoutePhase.replaying);
    expect(c.nextLandmark!.id, 'mock-corner');
    await tapRoute(t, 'route-step');
    await t.pump();
    expect(c.nextLandmark!.id, 'mock-end');
    await tapRoute(t, 'route-step');
    await t.pump();
    expect(c.phase, RoutePhase.arrival);
    expect(c.phase, isNot(RoutePhase.finished));
    await tapRoute(t, 'route-confirm-arrival');
    await t.pump();
    expect(c.phase, RoutePhase.finished);
    await tapRoute(t, 'route-select-$id');
    await t.pump();
    await tapRoute(t, 'route-delete');
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('route-confirm-delete')), findsOneWidget);
    await tapRoute(t, 'route-confirm-delete');
    await t.pumpAndSettle();
    expect(c.routes, isEmpty);
  });

  testWidgets('unknown withdraws direction; reconfirm resets', (t) async {
    await t.pumpWidget(
      _page(c, AppSettings.memory(language: AppLanguage.english)),
    );
    await tapRoute(t, 'route-start-recording');
    await t.pump();
    for (var i = 0; i < 3; i++) {
      await tapRoute(t, 'route-add-landmark');
      await t.pump();
    }
    await tapRoute(t, 'route-review');
    await t.pump();
    await t.enterText(find.byKey(const ValueKey('route-name')), 'R');
    await t.pump();
    await tapRoute(t, 'route-save');
    await t.pump();
    await tapRoute(t, 'route-select-${c.routes.first.id}');
    await t.pump();
    await tapRoute(t, 'route-confirm-start');
    await tapRoute(t, 'route-confirm-direction');
    await t.pump();
    await tapRoute(t, 'route-start-replay');
    await t.pump();
    await tapRoute(t, 'route-unknown');
    await t.pump();
    expect(c.phase, RoutePhase.unknown);
    expect(c.nextLandmark, isNull);
    expect(find.textContaining('Mock next landmark'), findsNothing);
    await tapRoute(t, 'route-reconfirm');
    await t.pump();
    expect(c.phase, RoutePhase.confirming);
    expect(c.startConfirmed, isFalse);
    expect(c.directionConfirmed, isFalse);
    expect(c.phase, isNot(RoutePhase.replaying));
  });
}
