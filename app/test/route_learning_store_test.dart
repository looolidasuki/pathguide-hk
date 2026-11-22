import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/encrypted_route_store.dart';
import 'package:pathguide/route_memory/route_learning_store.dart';

class Vault implements RouteKeyVault {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> write(List<int> bytes) async {
    key = List.of(bytes);
  }
}

void main() {
  late Directory root;
  late Vault vault;
  late RouteLearningStore store;
  var now = DateTime.utc(2026, 11, 7);
  Future<String> add({
    String route = 'route-one',
    String trip = 'trip-one',
    int image = 1,
  }) => store.add(
    routeId: route,
    routeVersion: 3,
    tripId: trip,
    session: 'session-one',
    sequence: image,
    requestedNode: 'requested-node',
    result: 'ambiguous',
    jpeg: Uint8List.fromList([255, 216, image, 255, 217]),
    feature: Uint8List.fromList([image, 2, 3]),
    featureProfile: 'vision-featureprint-v1',
    preprocessProfile: 'upright-jpeg-v1',
  );
  Matcher fails(String code) =>
      throwsA(isA<LearningStoreFailure>().having((e) => e.code, 'code', code));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('learning-test-');
    vault = Vault();
    now = DateTime.utc(2026, 11, 7);
    store = await RouteLearningStore.open(
      root: root,
      vault: vault,
      clock: () => now,
    );
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'encrypted reopen preserves prediction and independent review revisions',
    () async {
      final id = await add();
      expect(await store.list(), [id]);
      await store.review(
        id,
        expectedRevision: 0,
        decision: LearningReview.verified,
        reviewer: 'developer',
        reason: 'Checked actual door on site',
        node: 'actual-node',
        floor: '3F',
        directionChecked: true,
        exitChecked: true,
      );
      store = await RouteLearningStore.open(
        root: root,
        vault: vault,
        clock: () => now,
      );
      final data = await store.read(id);
      expect(data['prediction'], 'ambiguous');
      expect(data['requestedNode'], 'requested-node');
      expect(data['revision'], 1);
      expect((data['reviews'] as List).single['node'], 'actual-node');
      await for (final f in store.directory.list(recursive: true)) {
        if (f is File && !f.path.endsWith('.lock')) {
          final text = latin1.decode(await f.readAsBytes());
          expect(text, isNot(contains('actual-node')));
          expect(text, isNot(contains('developer')));
          expect(text, isNot(contains('route-one')));
        }
      }
    },
  );
  test(
    'unknown cannot be approved; competing revisions cannot overwrite',
    () async {
      final id = await add();
      await expectLater(
        store.review(
          id,
          expectedRevision: 0,
          decision: LearningReview.verified,
          reviewer: 'tester',
          reason: 'Not enough location evidence',
        ),
        fails('invalid'),
      );
      await store.review(
        id,
        expectedRevision: 0,
        decision: LearningReview.needsInformation,
        reviewer: 'tester',
        reason: 'Need floor confirmation',
      );
      await expectLater(
        store.review(
          id,
          expectedRevision: 0,
          decision: LearningReview.rejected,
          reviewer: 'tester',
          reason: 'Stale review must not overwrite',
        ),
        fails('conflict'),
      );
      expect((await store.read(id))['state'], 'needsInformation');
    },
  );
  test(
    'duplicates and per-trip capacity are bounded without altering records',
    () async {
      final id = await add();
      await expectLater(add(), fails('duplicate'));
      for (var i = 2; i <= RouteLearningStore.maxPerTrip; i++) {
        await add(image: i);
      }
      await expectLater(add(image: 99), fails('capacity'));
      expect((await store.list()).length, RouteLearningStore.maxPerTrip);
      expect((await store.read(id))['revision'], 0);
    },
  );
  test(
    'seven-day expiry blocks reads and explicit cleanup erases expired media',
    () async {
      final id = await add();
      now = now.add(const Duration(days: 7));
      expect(await store.list(), isEmpty);
      await expectLater(store.read(id), fails('expired'));
      await store.cleanup();
      await expectLater(store.read(id), fails('missing'));
      final files = await store.directory
          .list(recursive: true)
          .where((e) => e is File)
          .toList();
      expect(files.map((f) => f.uri.pathSegments.last).toSet(), {
        'catalog.enc',
        '.lock',
      });
    },
  );
  test('deleted route cannot be recreated and other route survives', () async {
    final id = await add();
    final other = await add(route: 'other-route', trip: 'other-trip', image: 4);
    await store.deleteRoute('route-one');
    await expectLater(store.read(id), fails('missing'));
    await expectLater(add(image: 5), fails('deleted'));
    expect(await store.list(), [other]);
  });

  test(
    'route capacity spans trips and expired rows free it on the next add',
    () async {
      for (var i = 0; i < RouteLearningStore.maxPerRoute; i++) {
        await add(trip: 'trip-$i', image: i + 1);
      }
      await expectLater(add(trip: 'extra'), fails('capacity'));
      final other = await add(route: 'route-two', trip: 'other');
      expect(await store.list(routeId: 'route-one'), hasLength(24));
      expect(await store.list(routeId: 'route-two'), [other]);
      now = now.add(RouteLearningStore.retention);
      final next = await add(trip: 'extra');
      expect(await store.list(), [next]);
    },
  );
  test('cancel before catalog switch never publishes late evidence', () async {
    final entered = Completer<void>(), release = Completer<void>();
    store = await RouteLearningStore.open(
      root: root,
      vault: vault,
      clock: () => now,
      checkpoint: () async {
        entered.complete();
        await release.future;
      },
    );
    final adding = add();
    final assertion = expectLater(adding, fails('cancelled'));
    await entered.future;
    store.cancelPending();
    release.complete();
    await assertion;
    expect(await store.list(), isEmpty);
  });
  test('missing key fails closed without clearing evidence', () async {
    final id = await add();
    vault.key = null;
    await expectLater(store.read(id), fails('keyUnavailable'));
    expect(await store.directory.list().isEmpty, isFalse);
  });
  test(
    'tampered ciphertext is rejected without silently deleting it',
    () async {
      final id = await add();
      final file = await store.directory
          .list(recursive: true)
          .where(
            (e) =>
                e is File &&
                e.path.endsWith('.enc') &&
                e.uri.pathSegments.last != 'catalog.enc',
          )
          .cast<File>()
          .single;
      final bytes = await file.readAsBytes();
      bytes[16] ^= 1;
      await file.writeAsBytes(bytes, flush: true);
      await expectLater(store.read(id), fails('corrupt'));
      expect(await file.exists(), isTrue);
    },
  );
}
