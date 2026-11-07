import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pathguide/route_memory/route_library_controller.dart';
import 'package:pathguide/route_memory/route_library_page.dart';
import 'package:pathguide/route_memory/route_package.dart';
import 'package:pathguide/settings/app_settings.dart';

class FakeBackend implements RouteLibraryBackend {
  RouteLibraryListing listing;
  Completer<void>? listGate;
  RouteProblem? saveProblem;
  int saves = 0, deletes = 0, rollbacks = 0, cleanups = 0, cancels = 0;
  String? saveId, saveName;
  bool? saveDraft;
  int? rollbackVersion, rollbackExpected;
  String? deletedId;
  FakeBackend(this.listing);

  RouteLibraryEntry _r({
    int? active,
    int? draft,
    int revision = 1,
    List<int> versions = const [1, 2],
    List<int> rollback = const [1],
  }) => RouteLibraryEntry(
    id: 'r',
    name: 'Sample',
    revision: revision,
    versions: versions,
    rollbackVersions: rollback,
    activeVersion: active,
    draftVersion: draft,
  );

  void seedActive2() =>
      listing = RouteLibraryListing([_r(active: 2, revision: 2)], 0);

  @override
  Future<RouteLibraryListing> list() async {
    if (listGate != null) await listGate!.future;
    return listing;
  }

  @override
  Future<void> saveSample(String id, String name, bool draft, int exp) async {
    saves++;
    saveId = id;
    saveName = name;
    saveDraft = draft;
    if (saveProblem != null) throw RouteStoreFailure(saveProblem!);
    final version = listing.routes.isEmpty
        ? 1
        : listing.routes.single.versions.last + 1;
    final next = RouteLibraryEntry(
      id: id,
      name: name,
      revision: exp + 1,
      versions: listing.routes.isEmpty
          ? [version]
          : [...listing.routes.single.versions, version],
      rollbackVersions: draft
          ? []
          : listing.routes.isEmpty
          ? []
          : [1],
      activeVersion: draft
          ? (listing.routes.isEmpty
                ? null
                : listing.routes.single.activeVersion)
          : version,
      draftVersion: draft ? version : null,
    );
    listing = RouteLibraryListing([next], listing.pendingCleanup);
  }

  @override
  Future<void> rollback(String id, int version, int exp) async {
    rollbacks++;
    rollbackVersion = version;
    rollbackExpected = exp;
    listing = RouteLibraryListing([_r(active: version, revision: 2)], 0);
  }

  @override
  Future<void> delete(String id, int exp) async {
    deletes++;
    deletedId = id;
    listing = RouteLibraryListing(
      listing.routes.where((e) => e.id != id).toList(),
      listing.pendingCleanup,
    );
  }

  @override
  Future<void> cleanup() async {
    cleanups++;
  }

  @override
  void cancelPending() {
    cancels++;
  }
}

FakeBackend _fake({bool seed = true}) => FakeBackend(
  RouteLibraryListing(
    seed
        ? [
            RouteLibraryEntry(
              id: 'r',
              name: 'Sample',
              revision: 2,
              versions: const [1, 2],
              rollbackVersions: const [1],
              activeVersion: 2,
            ),
          ]
        : const [],
    0,
  ),
);

Future<void> _scrollTo(WidgetTester t, Finder f) async {
  t.testTextInput.hide();
  await t.pump();
  await t.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
  await t.pump();
}

Widget _page(RouteLibraryController c, AppSettings s, VoidCallback onBack) =>
    MaterialApp(
      home: Scaffold(
        body: RouteLibraryPage(controller: c, settings: s, onBack: onBack),
      ),
    );

void main() {
  testWidgets('layout: zh/en 320x568 textScale2 keyboard insets', (t) async {
    t.view.physicalSize = const Size(320, 568);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    t.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    for (final en in [false, true]) {
      t.view.resetViewInsets();
      final backend = _fake(seed: false);
      final c = RouteLibraryController(backend);
      final s = AppSettings.memory();
      await s.setLanguage(en ? AppLanguage.english : AppLanguage.chinese);
      await t.pumpWidget(_page(c, s, () {}));
      await t.pumpAndSettle();
      expect(
        find.byKey(const Key('library-back')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('library-pause')).hitTestable(),
        findsOneWidget,
      );
      final w = t.getSize(find.byKey(const Key('library-back'))).height;
      expect(w, greaterThanOrEqualTo(48));
      final p = t.getSize(find.byKey(const Key('library-pause'))).height;
      expect(p, greaterThanOrEqualTo(48));
      expect(
        MediaQuery.textScalerOf(t.element(find.byType(RouteLibraryPage)))
            .scale(1),
        2,
      );
      expect(find.text('p0'), findsNothing);
      final field = find.byKey(const Key('library-name'));
      await t.scrollUntilVisible(
        field,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(t.element(field), alignment: 0.5);
      await t.pumpAndSettle();
      expect(field.hitTestable(), findsOneWidget);
      await t.tap(field);
      expect(t.testTextInput.isVisible, isTrue);
      await t.pumpAndSettle();
      expect(find.textContaining('Working'), findsNothing);
      t.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(t.view.resetViewInsets);
      await t.pump();
      expect(t.takeException(), isNull);
      expect(
        find.byKey(const Key('library-back')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('library-pause')).hitTestable(),
        findsOneWidget,
      );
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
      c.dispose();
      s.dispose();
    }
  });

  testWidgets('empty -> save draft -> activate complete', (t) async {
    final backend = _fake(seed: false);
    final c = RouteLibraryController(backend);
    final s = AppSettings.memory();
    await t.pumpWidget(_page(c, s, () {}));
    await t.pumpAndSettle();
    expect(c.entries, isEmpty);
    await t.enterText(find.byKey(const Key('library-name')), 'Draft one');
    t.testTextInput.hide();
    await t.pump();
    await _scrollTo(t, find.byKey(const Key('library-save-draft')));
    await t.tap(find.byKey(const Key('library-save-draft')));
    await t.pumpAndSettle();
    expect(backend.saves, 1);
    expect(c.entries.single.draftVersion, 1);
    expect(c.entries.single.activeVersion, isNull);
    final id = c.entries.single.id;
    await _scrollTo(t, find.byKey(Key('library-version-$id')));
    await t.tap(find.byKey(Key('library-version-$id')));
    await t.pumpAndSettle();
    expect(c.entries.single.activeVersion, 2);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    c.dispose();
    s.dispose();
  });

  testWidgets('rollback then delete dialog cancel/confirm', (t) async {
    final backend = _fake();
    final c = RouteLibraryController(backend);
    final s = AppSettings.memory();
    await t.pumpWidget(_page(c, s, () {}));
    await t.pumpAndSettle();
    await _scrollTo(t, find.byKey(const Key('library-rollback-r-1')));
    await t.tap(find.byKey(const Key('library-rollback-r-1')));
    await t.pumpAndSettle();
    expect(backend.rollbacks, 1);
    expect(backend.rollbackVersion, 1);
    expect(c.entries.single.activeVersion, 1);
    await _scrollTo(t, find.byKey(const Key('library-delete-r')));
    await t.tap(find.byKey(const Key('library-delete-r')));
    await t.pumpAndSettle();
    await t.tap(find.text('取消').last);
    await t.pumpAndSettle();
    expect(backend.deletes, 0);
    expect(c.entries, hasLength(1));
    await _scrollTo(t, find.byKey(const Key('library-delete-r')));
    await t.tap(find.byKey(const Key('library-delete-r')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('library-confirm-delete')));
    await t.pumpAndSettle();
    expect(backend.deletes, 1);
    expect(c.entries, isEmpty);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    c.dispose();
    s.dispose();
  });

  testWidgets('dialog invalidated by lifecycle; refresh resumes', (t) async {
    final backend = _fake();
    final c = RouteLibraryController(backend);
    final s = AppSettings.memory();
    await t.pumpWidget(_page(c, s, () {}));
    await t.pumpAndSettle();
    await _scrollTo(t, find.byKey(const Key('library-delete-r')));
    await t.tap(find.byKey(const Key('library-delete-r')));
    await t.pumpAndSettle();
    c.setForeground(false);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('library-confirm-delete')));
    await t.pumpAndSettle();
    expect(backend.deletes, 0);
    expect(c.paused, isTrue);
    c.setForeground(true);
    await t.pumpAndSettle();
    await _scrollTo(t, find.byKey(const Key('library-refresh')));
    await t.tap(find.byKey(const Key('library-refresh')));
    await t.pumpAndSettle();
    expect(c.paused, isFalse);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    c.dispose();
    s.dispose();
  });

  testWidgets('capacity failure localizes; no retry; refresh reads', (t) async {
    final backend = _fake(seed: false)..saveProblem = RouteProblem.capacity;
    final c = RouteLibraryController(backend);
    final s = AppSettings.memory();
    await t.pumpWidget(_page(c, s, () {}));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('library-name')), 'X');
    t.testTextInput.hide();
    await t.pump();
    await _scrollTo(t, find.byKey(const Key('library-save-draft')));
    await t.tap(find.byKey(const Key('library-save-draft')));
    await t.pumpAndSettle();
    expect(backend.saves, 1);
    expect(c.error, RouteProblem.capacity);
    expect(find.textContaining('清理'), findsWidgets);
    expect(find.text('Saved.'), findsNothing);
    expect(find.text('已儲存。'), findsNothing);
    await _scrollTo(t, find.byKey(const Key('library-refresh')));
    await t.tap(find.byKey(const Key('library-refresh')));
    await t.pumpAndSettle();
    expect(backend.saves, 1);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    c.dispose();
    s.dispose();
  });

  testWidgets('delayed list after pause/disposal: no stale success', (t) async {
    final backend = _fake(seed: false);
    backend.listGate = Completer<void>();
    final c = RouteLibraryController(backend);
    final s = AppSettings.memory();
    await t.pumpWidget(_page(c, s, () {}));
    await t.pump();
    expect(c.busy, isTrue);
    c.setForeground(false);
    backend.listGate!.complete();
    await t.pumpAndSettle();
    expect(c.entries, isEmpty);
    expect(c.paused, isTrue);
    backend.listGate = null;
    c.setForeground(true);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    c.dispose();
    s.dispose();
  });
}
