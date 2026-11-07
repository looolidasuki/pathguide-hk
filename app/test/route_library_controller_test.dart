import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/route_library_controller.dart';
import 'package:pathguide/route_memory/route_package.dart';

class TestRouteBackend implements RouteLibraryBackend {
  RouteLibraryListing listing = RouteLibraryListing([], 0);
  Completer<RouteLibraryListing>? waiting;
  RouteProblem? saveProblem;
  int saves = 0, reads = 0, invalidations = 0;
  @override
  Future<RouteLibraryListing> list() async {
    reads++;
    return waiting?.future ?? listing;
  }

  @override
  Future<void> saveSample(
    String id,
    String name,
    bool draft,
    int expectedRevision,
  ) async {
    saves++;
    if (saveProblem != null) throw RouteStoreFailure(saveProblem!);
    listing = RouteLibraryListing([
      RouteLibraryEntry(
        id: id,
        name: name,
        revision: 1,
        versions: [1],
        rollbackVersions: [],
        activeVersion: draft ? null : 1,
        draftVersion: draft ? 1 : null,
      ),
    ], 0);
  }

  @override
  Future<void> delete(String id, int expectedRevision) async {
    listing = RouteLibraryListing([], 0);
  }

  @override
  Future<void> rollback(String id, int version, int expectedRevision) async {}
  @override
  Future<void> cleanup() async {}
  @override
  void cancelPending() {
    invalidations++;
  }
}

void main() {
  test('draft save only reports success after reconciled listing', () async {
    final backend = TestRouteBackend();
    final c = RouteLibraryController(backend);
    addTearDown(c.dispose);
    await c.addSample('sample', draft: true);
    expect(c.notice, LibraryNotice.saved);
    expect(c.entries.single.activeVersion, isNull);
    expect(c.entries.single.draftVersion, 1);
  });
  test(
    'uncertain write is read once for reconciliation, never retried',
    () async {
      final backend = TestRouteBackend()
        ..saveProblem = RouteProblem.outcomeUnknown;
      final c = RouteLibraryController(backend);
      addTearDown(c.dispose);
      await c.addSample('sample', draft: false);
      expect(c.error, RouteProblem.outcomeUnknown);
      expect(backend.saves, 1);
      expect(backend.reads, 1);
      expect(c.notice, LibraryNotice.ready);
    },
  );
  for (final operation in ['pause', 'background', 'dispose']) {
    test(
      '$operation discards delayed listing and invalidates pending writes',
      () async {
        final backend = TestRouteBackend()
          ..waiting = Completer<RouteLibraryListing>();
        final c = RouteLibraryController(backend);
        final loading = c.refresh();
        expect(c.busy, isTrue);
        if (operation == 'dispose') {
          c.dispose();
        } else if (operation == 'pause') {
          c.pause();
        } else {
          c.setForeground(false);
          c.setForeground(true);
        }
        backend.waiting!.complete(
          RouteLibraryListing([
            RouteLibraryEntry(
              id: 'late',
              name: 'late',
              revision: 1,
              versions: [1],
              rollbackVersions: [],
              activeVersion: 1,
            ),
          ], 0),
        );
        await loading;
        expect(c.entries, isEmpty);
        expect(backend.invalidations, 1);
        if (operation != 'dispose') {
          expect(c.paused, isTrue);
          expect(c.busy, isFalse);
          backend.waiting = null;
          await c.refresh();
          expect(c.paused, isFalse);
          c.dispose();
        }
      },
    );
  }
  test('double tap while listing pending does not duplicate save', () async {
    final backend = TestRouteBackend()
      ..waiting = Completer<RouteLibraryListing>();
    final c = RouteLibraryController(backend);
    addTearDown(c.dispose);
    final first = c.addSample('sample', draft: false);
    await c.addSample('duplicate', draft: false);
    expect(backend.saves, 1);
    backend.waiting!.complete(backend.listing);
    await first;
    expect(c.entries.single.name, 'sample');
  });
}
