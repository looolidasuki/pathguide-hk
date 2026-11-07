import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/cross_floor_contract.dart';
import 'package:pathguide/route_memory/cross_floor_mock_fixtures.dart';
import 'package:pathguide/route_memory/cross_floor_mock_page.dart';
import 'package:pathguide/settings/app_settings.dart';

Future<void> scrollTap(WidgetTester t, Key key) async {
  final f = find.byKey(key);
  await t.scrollUntilVisible(f, 40, scrollable: find.byType(Scrollable).first);
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  late MockJourneyClock clock;
  late CrossFloorController c;
  late AppSettings settings;

  Future<void> mount(
    WidgetTester t, {
    bool clearFirst = false,
    VoidCallback? onBack,
  }) async {
    clock = MockJourneyClock();
    c = CrossFloorController(
      route: crossFloorFixture(),
      elapsed: clock.elapsed,
    );
    settings = AppSettings.memory(language: AppLanguage.chinese);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CrossFloorMockPage(
            controller: c,
            settings: settings,
            onBack: onBack ?? () {},
          ),
        ),
      ),
    );
    if (clearFirst) {
      await scrollTap(t, const ValueKey('p0-start'));
      await scrollTap(t, const ValueKey('p0-clear'));
    }
  }

  Future<void> teardown(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    c.dispose();
    settings.dispose();
  }

  for (final lang in AppLanguage.values) {
    testWidgets('layout ${lang.name}', (t) async {
      t.view.physicalSize = const Size(320, 568);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      t.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await mount(t);
      await settings.setLanguage(lang);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      for (final k in ['p0-back', 'p0-pause']) {
        final f = find.byKey(ValueKey(k));
        expect(f.hitTestable(), findsOneWidget);
        expect(t.getSize(f).height, greaterThanOrEqualTo(48));
        expect(t.getRect(f).top, greaterThan(0));
      }
      expect(find.text('p0-start'), findsNothing);
      await teardown(t);
    });
  }

  for (final lang in AppLanguage.values) {
    testWidgets('journey ${lang.name} narrow 2x', (t) async {
      t.view.physicalSize = const Size(320, 568);
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(t.view.reset);
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await mount(t);
      await settings.setLanguage(lang);
      await t.pumpAndSettle();
      expect(
        find.text(lang == AppLanguage.chinese ? '跨樓層模擬' : 'Cross-floor MOCK'),
        findsOneWidget,
      );
      await scrollTap(t, const ValueKey('p0-start'));
      expect(c.phase, FloorPhase.walkingOnFloor);
      clock.advance(const Duration(milliseconds: 100));
      await scrollTap(t, const ValueKey('p0-next'));
      expect(c.phase, FloorPhase.approachingConnector);
      clock.advance(const Duration(milliseconds: 100));
      await scrollTap(t, const ValueKey('p0-enter'));
      expect(c.phase, FloorPhase.transitioning);
      clock.advance(const Duration(milliseconds: 100));
      await scrollTap(t, const ValueKey('p0-wrong'));
      expect(c.actualFloor, isNull);
      expect(c.canConfirmFloor, isFalse);
      clock.advance(const Duration(milliseconds: 100));
      await scrollTap(t, const ValueKey('p0-ambiguous'));
      expect(c.canConfirmFloor, isFalse);
      clock.advance(const Duration(milliseconds: 100));
      await scrollTap(t, const ValueKey('p0-third'));
      expect(c.canConfirmFloor, isTrue);
      await scrollTap(t, const ValueKey('p0-confirm-floor'));
      expect(c.phase, FloorPhase.relocalizingExit);
      clock.advance(const Duration(milliseconds: 100));
      await scrollTap(t, const ValueKey('p0-exit'));
      expect(c.actualFloor, mockThird);
      expect(c.phase, FloorPhase.walkingOnFloor);
      clock.advance(const Duration(milliseconds: 100));
      await scrollTap(t, const ValueKey('p0-clear'));
      clock.advance(const Duration(milliseconds: 100));
      await scrollTap(t, const ValueKey('p0-next'));
      expect(c.phase, FloorPhase.arrival);
      clock.advance(const Duration(milliseconds: 100));
      await scrollTap(t, const ValueKey('p0-arrival'));
      expect(c.phase, FloorPhase.finished);
      await teardown(t);
    });
  }

  testWidgets('critical clears readback', (t) async {
    await mount(t, clearFirst: true);
    await scrollTap(t, const ValueKey('p0-read'));
    expect(
      t.widget<Text>(find.byKey(const ValueKey('p0-readback'))).data,
      contains('地下轉層入口'),
    );
    await scrollTap(t, const ValueKey('p0-urgent'));
    expect(find.byKey(const ValueKey('p0-readback')), findsNothing);
    await scrollTap(t, const ValueKey('p0-read'));
    expect(
      t.widget<Text>(find.byKey(const ValueKey('p0-readback'))).data,
      '合成障礙提示',
    );
    await settings.setLanguage(AppLanguage.english);
    await t.pumpAndSettle();
    expect(
      t.widget<Text>(find.byKey(const ValueKey('p0-readback'))).data,
      'Synthetic obstacle notice',
    );
    c.match(
      c.observe(EvidenceChannel.location)!,
      FloorMatch.matched,
      nodeId: 'g-connector',
      floor: mockGround,
    );
    await t.pumpAndSettle();
    await scrollTap(t, const ValueKey('p0-clear'));
    await scrollTap(t, const ValueKey('p0-read'));
    expect(c.guidance!.kind, GuidanceKind.floorConfirmation);
    expect(c.guidance!.node, isNull);
    expect(
      t.widget<Text>(find.byKey(const ValueKey('p0-readback'))).data,
      'Head to the connector (3F)',
    );
    await teardown(t);
  });

  testWidgets('lifecycle pauses without auto resume', (t) async {
    await mount(t);
    await scrollTap(t, const ValueKey('p0-start'));
    final old = c.observe(EvidenceChannel.location);
    expect(old, isNotNull);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pumpAndSettle();
    expect(c.phase, FloorPhase.paused);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(c.phase, FloorPhase.paused);
    await scrollTap(t, const ValueKey('p0-relocalize'));
    expect(c.phase, FloorPhase.walkingOnFloor);
    expect(c.actualFloor, mockThird);
    expect(c.nextNode!.id, '3-room');
    c.match(old!, FloorMatch.matched, nodeId: 'g-connector', floor: mockGround);
    expect(c.nextNode!.id, '3-room');
    await teardown(t);
  });

  testWidgets('delete blocks callbacks', (t) async {
    var backed = false;
    await mount(t, onBack: () => backed = true);
    await scrollTap(t, const ValueKey('p0-start'));
    final old = c.observe(EvidenceChannel.location)!;
    await t.tap(find.byKey(const ValueKey('p0-back')));
    await t.pumpAndSettle();
    expect(backed, isTrue);
    expect(c.phase, FloorPhase.paused);
    await scrollTap(t, const ValueKey('p0-delete'));
    expect(c.phase, FloorPhase.deleted);
    expect(c.observe(EvidenceChannel.location), isNull);
    await scrollTap(t, const ValueKey('p0-start'));
    expect(c.phase, FloorPhase.deleted);
    c.match(old, FloorMatch.matched, nodeId: 'g-connector', floor: mockGround);
    expect(c.phase, FloorPhase.deleted);
    await teardown(t);
  });
}
