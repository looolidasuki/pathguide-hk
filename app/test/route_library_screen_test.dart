import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/route_library_controller.dart';
import 'package:pathguide/route_memory/route_library_screen.dart';
import 'package:pathguide/settings/app_settings.dart';

import 'route_library_controller_test.dart' show TestRouteBackend;

void main() {
  testWidgets(
    'late store opening after leave is disposed without loading or saving',
    (t) async {
      final backend = TestRouteBackend();
      final opened = Completer<RouteLibraryController>();
      final settings = AppSettings.memory();
      await t.pumpWidget(
        MaterialApp(
          home: RouteLibraryScreen(
            settings: settings,
            createController: () => opened.future,
          ),
        ),
      );
      await t.pump();
      await t.pumpWidget(const SizedBox());
      opened.complete(RouteLibraryController(backend));
      await t.pumpAndSettle();
      expect(backend.reads, 0);
      expect(backend.saves, 0);
      expect(backend.invalidations, 1);
      expect(t.takeException(), isNull);
      settings.dispose();
    },
  );
  testWidgets('opening while background does not load until explicit refresh', (
    t,
  ) async {
    final backend = TestRouteBackend();
    final opened = Completer<RouteLibraryController>();
    final settings = AppSettings.memory();
    await t.pumpWidget(
      MaterialApp(
        home: RouteLibraryScreen(
          settings: settings,
          createController: () => opened.future,
        ),
      ),
    );
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    opened.complete(RouteLibraryController(backend));
    await t.pumpAndSettle();
    expect(backend.reads, 0);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(backend.reads, 0);
    final refresh = find.byKey(const ValueKey('library-refresh'));
    await t.scrollUntilVisible(
      refresh,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(refresh);
    await t.pumpAndSettle();
    expect(backend.reads, 1);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    settings.dispose();
  });
}
