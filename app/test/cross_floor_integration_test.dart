import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/main.dart';
import 'package:pathguide/route_memory/cross_floor_contract.dart';
import 'package:pathguide/route_memory/cross_floor_mock_page.dart';
import 'package:pathguide/route_memory/route_memory_contract.dart';
import 'package:pathguide/route_memory/route_memory_mock_page.dart';
import 'package:pathguide/settings/app_settings.dart';

void main() {
  testWidgets(
    'home opens cross-floor preset; leaving pauses both mocks without hardware',
    (t) async {
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
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
      final settings = AppSettings.memory();
      await t.pumpWidget(PathGuideApp(settings: settings));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('設定與使用教學'));
      await t.tap(find.text('設定與使用教學'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('開發測試'));
      await t.tap(find.text('開發測試'));
      await t.pumpAndSettle();
      final entry = find.text('室內路線工具（試驗）');
      await t.scrollUntilVisible(
        entry,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(entry);
      await t.pumpAndSettle();
      await t.tap(find.text('略過說明'));
      await t.pumpAndSettle();
      final original = t
          .widget<RouteMemoryMockPage>(find.byType(RouteMemoryMockPage))
          .controller;
      original.startRecording();
      await t.pumpAndSettle();
      final cross = find.byKey(const ValueKey('route-cross-floor'));
      await t.ensureVisible(cross);
      await t.tap(cross);
      await t.pumpAndSettle();
      expect(original.phase, RoutePhase.pausedRecording);
      final c = t
          .widget<CrossFloorMockPage>(find.byType(CrossFloorMockPage))
          .controller;
      final start = find.byKey(const ValueKey('p0-start'));
      await t.ensureVisible(start);
      await t.tap(start);
      await t.pumpAndSettle();
      final late = c.observe(EvidenceChannel.location)!;
      // System back/swipe must also invalidate; it does not use p0-back callback.
      Navigator.of(t.element(find.byType(CrossFloorMockPage))).pop();
      await t.pumpAndSettle();
      c.match(
        late,
        FloorMatch.matched,
        nodeId: 'g-connector',
        floor: c.route.nodes.first.floor,
      );
      expect(find.byType(CrossFloorMockPage), findsNothing);
      expect(find.byType(RouteMemoryMockPage), findsOneWidget);
      expect(original.phase, RoutePhase.pausedRecording);
      expect(c.guidance, isNull); // Disposed route owner withdrew its event.
      expect(calls, isEmpty);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
      settings.dispose();
    },
  );
}
