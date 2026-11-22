import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/cross_floor_contract.dart';
import 'package:pathguide/route_memory/encrypted_route_store.dart';
import 'package:pathguide/route_memory/device_route_library.dart';
import 'package:pathguide/route_memory/route_package.dart';

class MemoryRouteVault implements RouteKeyVault {
  List<int>? bytes;
  int writes = 0;
  @override
  Future<List<int>?> read() async => bytes == null ? null : List.of(bytes!);
  @override
  Future<void> write(List<int> value) async {
    bytes = List.of(value);
    writes++;
  }
}

RouteDocument document({
  String id = 'route-a',
  String name = '私人跨樓層路線',
  bool draft = false,
  String feature = 'p0-synthetic-v1',
}) => RouteDocument(
  id: id,
  name: name,
  buildingId: 'building',
  featureRevision: feature,
  nodes: [
    const RoutePoint(
      'g',
      '地下',
      'Ground',
      floor: FloorRef('building', 'g', 'G'),
    ),
    RoutePoint(
      'three',
      '三樓',
      'Third',
      floor: draft ? null : const FloorRef('building', 'three', '3F'),
    ),
  ],
  edges: [
    RouteSegment(
      'g',
      'three',
      ConnectorMode.elevator,
      connectorId: draft ? null : 'lift',
      confirmed: !draft,
    ),
  ],
);

Matcher fails(RouteProblem problem) =>
    isA<RouteStoreFailure>().having((e) => e.problem, 'problem', problem);

void main() {
  late Directory root;
  late MemoryRouteVault vault;
  late EncryptedRouteStore store;
  Future<RouteSnapshot> put({
    int revision = 0,
    RouteDocument? doc,
    bool active = true,
    EncryptedRouteStore? using,
  }) {
    final s = using ?? store;
    final d = doc ?? document();
    return s.save(
      d,
      token: s.capture(d.id),
      expectedRevision: revision,
      activate: active,
    );
  }

  Future<List<File>> revisions() async => [
    await for (final f in store.directory.list(recursive: true))
      if (f is File &&
          f.path.endsWith('.enc') &&
          !f.path.endsWith('catalog.enc'))
        f,
  ];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('pathguide-route-test-');
    vault = MemoryRouteVault();
    store = await EncryptedRouteStore.open(root: root, vault: vault);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('late closing owner cannot cancel another owner write', () async {
    final second = await EncryptedRouteStore.open(root: root, vault: vault);
    final token = second.capture('route-a');
    store.cancelPending();
    await second.save(
      document(),
      token: token,
      expectedRevision: 0,
      activate: true,
    );
    expect((await second.read('route-a')).version, 1);
  });
  test(
    'device adapter stores explicit synthetic draft then complete structure',
    () async {
      final backend = DeviceRouteLibrary(store);
      await backend.saveSample('sample', '跨樓層', true, 0);
      final draft = await store.read('sample');
      expect(draft.document.toMap()['source'], 'synthetic');
      expect(draft.document.nodes.any((n) => n.floor == null), isTrue);
      expect(draft.published, isFalse);
      await backend.saveSample('sample', '跨樓層', false, 1);
      expect((await store.read('sample')).published, isTrue);
      expect((await store.list()).routes.single.activeVersion, 2);
    },
  );

  test(
    'reopen decrypts stable immutable version with scoped floors and SHA',
    () async {
      expect((await store.list()).routes, isEmpty);
      final saved = await put();
      store = await EncryptedRouteStore.open(root: root, vault: vault);
      final loaded = await store.read('route-a');
      expect(loaded.document.name, document().name);
      expect(loaded.document.nodes.last.floor!.label, '3F');
      expect(loaded.manifestSha, saved.manifestSha);
      expect(loaded.published, isTrue);
      expect(vault.writes, 1);
      expect((await store.list()).routes.single.activeVersion, 1);
    },
  );
  test(
    'disk files hide route names/nodes; revisions use different nonces',
    () async {
      await put();
      await put(revision: 1);
      final nonces = <String>{};
      await for (final f in store.directory.list(recursive: true)) {
        if (f is! File || !f.path.endsWith('.enc')) continue;
        final text = await f.readAsString();
        for (final secret in ['私人跨樓層路線', 'building', 'route-a', '三樓']) {
          expect(text, isNot(contains(secret)));
        }
        nonces.add((jsonDecode(text) as Map)['nonce'] as String);
      }
      expect(nonces.length, 3);
    },
  );
  test(
    'draft with unknown floor never replaces stable pointer or activates',
    () async {
      await put();
      await put(revision: 1, doc: document(draft: true), active: false);
      final entry = (await store.list()).routes.single;
      expect(entry.activeVersion, 1);
      expect(entry.draftVersion, 2);
      expect(
        (await store.read('route-a', version: 2)).document.nodes.last.floor,
        isNull,
      );
      await expectLater(
        put(revision: 2, doc: document(draft: true)),
        throwsA(fails(RouteProblem.invalid)),
      );
      expect((await store.read('route-a')).version, 1);
    },
  );
  test(
    'incompatible feature draft retained, activation/rollback refused',
    () async {
      await put(doc: document(feature: 'future'), active: false);
      expect(
        (await store.list()).routes.single.problem,
        RouteProblem.incompatible,
      );
      await expectLater(
        put(revision: 1, doc: document(feature: 'future')),
        throwsA(fails(RouteProblem.incompatible)),
      );
      await expectLater(
        store.rollback('route-a', 1, expectedRevision: 1),
        throwsA(fails(RouteProblem.incompatible)),
      );
    },
  );
  test(
    'immutable rollback changes pointer and CAS revision, not content versions',
    () async {
      final first = await put();
      await put(revision: 1, doc: document(name: '新版'));
      final oldBytes = [
        for (final f in await revisions()) await f.readAsBytes(),
      ];
      await store.rollback('route-a', 1, expectedRevision: 2);
      expect((await store.read('route-a')).manifestSha, first.manifestSha);
      final entry = (await store.list()).routes.single;
      expect(entry.revision, 3);
      expect(entry.activeVersion, 1);
      expect(entry.versions, [1, 2]);
      final after = [for (final f in await revisions()) await f.readAsBytes()];
      expect(after, oldBytes);
      await expectLater(
        put(revision: 2),
        throwsA(fails(RouteProblem.conflict)),
      );
    },
  );
  test(
    'corrupt active version preserved; explicit verified older rollback works',
    () async {
      await put();
      await put(revision: 1, doc: document(name: '新版'));
      final files = await revisions();
      // Determine active revision by corruption one at a time using catalog readback.
      final originals = {for (final f in files) f.path: await f.readAsBytes()};
      File? damaged;
      for (final f in files) {
        await f.writeAsString('damaged');
        try {
          await store.read('route-a');
        } on RouteStoreFailure {
          damaged = f;
          break;
        }
        await f.writeAsBytes(originals[f.path]!);
      }
      expect(damaged, isNotNull);
      expect((await store.list()).routes.single.rollbackVersions, [1]);
      expect((await store.list()).routes.single.problem, RouteProblem.corrupt);
      await store.cleanupUnreferenced();
      expect(await damaged!.readAsString(), 'damaged');
      await store.rollback('route-a', 1, expectedRevision: 2);
      expect((await store.read('route-a')).version, 1);
    },
  );
  test('failure before catalog switch leaves stable active version and orphan ignored', () async {
    await put();
    final broken = await EncryptedRouteStore.open(
      root: root,
      vault: vault,
      checkpoint: (step) async {
        if (step == 'beforeCatalogCommit') {
          throw const FileSystemException('disk full');
        }
      },
    );
    await expectLater(
      put(revision: 1, using: broken),
      throwsA(fails(RouteProblem.io)),
    );
    store = await EncryptedRouteStore.open(root: root, vault: vault);
    expect((await store.read('route-a')).version, 1);
    expect((await store.list()).routes.single.versions, [1]);
    await store.cleanupUnreferenced();
    expect((await revisions()).length, 1);
  });
  test('failure after commit is unknown outcome; refresh resolves without duplicate save', () async {
    await put();
    final broken = await EncryptedRouteStore.open(
      root: root,
      vault: vault,
      checkpoint: (step) async {
        if (step == 'afterCatalogCommit') throw StateError('interrupted');
      },
    );
    await expectLater(
      put(revision: 1, using: broken),
      throwsA(fails(RouteProblem.outcomeUnknown)),
    );
    expect((await store.read('route-a')).version, 2);
    await expectLater(put(revision: 1), throwsA(fails(RouteProblem.conflict)));
  });
  test('document quota and library quota preserve stable content', () async {
    await put();
    final tinyDoc = await EncryptedRouteStore.open(
      root: root,
      vault: vault,
      limits: const RouteStoreLimits(documentBytes: 20),
    );
    await expectLater(
      put(revision: 1, using: tinyDoc),
      throwsA(fails(RouteProblem.capacity)),
    );
    final tinyLibrary = await EncryptedRouteStore.open(
      root: root,
      vault: vault,
      limits: const RouteStoreLimits(libraryBytes: 1),
    );
    await expectLater(
      put(revision: 1, using: tinyLibrary),
      throwsA(fails(RouteProblem.capacity)),
    );
    expect((await store.read('route-a')).version, 1);
  });
  test('version limit prevents unlimited growth instead of deleting stable history', () async {
    final limited = await EncryptedRouteStore.open(
      root: root,
      vault: vault,
      limits: const RouteStoreLimits(versionsPerRoute: 2),
    );
    await put(using: limited);
    await put(revision: 1, using: limited);
    await expectLater(
      put(revision: 2, using: limited),
      throwsA(fails(RouteProblem.capacity)),
    );
    expect((await store.list()).routes.single.versions, [1, 2]);
  });
  test('missing key never regenerates over existing route data', () async {
    await put();
    final missing = MemoryRouteVault();
    final reopened = await EncryptedRouteStore.open(root: root, vault: missing);
    await expectLater(
      reopened.list(),
      throwsA(fails(RouteProblem.keyUnavailable)),
    );
    expect(missing.writes, 0);
    expect((await store.read('route-a')).version, 1);
  });
  test('wrong key/catalog tamper fail closed; no fallback resurrects deleted route', () async {
    await put();
    await store.delete('route-a', expectedRevision: 1);
    final wrong = MemoryRouteVault()..bytes = List.filled(32, 9);
    final reopened = await EncryptedRouteStore.open(root: root, vault: wrong);
    await expectLater(reopened.list(), throwsA(fails(RouteProblem.corrupt)));
    expect(wrong.writes, 0);
    final cat = File('${store.directory.path}/catalog.enc');
    await cat.writeAsString('broken');
    await expectLater(store.list(), throwsA(fails(RouteProblem.corrupt)));
    await expectLater(
      put(doc: document(id: 'new')),
      throwsA(fails(RouteProblem.corrupt)),
    );
    expect(await cat.readAsString(), 'broken');
  });
  test(
    'two instances serialize; stale expected revision prevents lost update',
    () async {
      final second = await EncryptedRouteStore.open(root: root, vault: vault);
      final first = put();
      final competing = expectLater(
        put(using: second),
        throwsA(fails(RouteProblem.conflict)),
      );
      await first;
      await competing;
      expect((await store.list()).routes.single.versions, [1]);
    },
  );
  for (final cancel in ['pause', 'delete']) {
    test('$cancel invalidates a write waiting before pointer commit', () async {
      await put();
      await put(doc: document(id: 'other'));
      final reached = Completer<void>(), release = Completer<void>();
      final slow = await EncryptedRouteStore.open(
        root: root,
        vault: vault,
        checkpoint: (step) async {
          if (step == 'beforeCatalogCommit') {
            reached.complete();
            await release.future;
          }
        },
      );
      final pending = expectLater(
        put(revision: 1, using: slow),
        throwsA(fails(RouteProblem.cancelled)),
      );
      await reached.future.timeout(const Duration(seconds: 3));
      Future<void>? deletion;
      if (cancel == 'delete') {
        deletion = store.delete('route-a', expectedRevision: 1);
      } else {
        slow.cancelPending();
      }
      release.complete();
      await pending;
      if (deletion != null) await deletion;
      store = await EncryptedRouteStore.open(root: root, vault: vault);
      expect((await store.read('other')).version, 1);
      if (cancel == 'delete') {
        expect((await store.list()).routes.map((r) => r.id), ['other']);
        await expectLater(put(), throwsA(fails(RouteProblem.deleted)));
      } else {
        expect((await store.read('route-a')).version, 1);
      }
    });
  }
  test(
    'durable tombstone precedes cleanup; restart cannot revive route',
    () async {
      await put();
      await put(doc: document(id: 'other'));
      final broken = await EncryptedRouteStore.open(
        root: root,
        vault: vault,
        checkpoint: (step) async {
          if (step == 'beforeDeleteCleanup') throw StateError('crash');
        },
      );
      await expectLater(
        broken.delete('route-a', expectedRevision: 1),
        throwsA(fails(RouteProblem.cleanupPending)),
      );
      store = await EncryptedRouteStore.open(root: root, vault: vault);
      expect((await store.list()).routes.map((r) => r.id), ['other']);
      expect((await store.list()).pendingCleanup, 1);
      await expectLater(put(), throwsA(fails(RouteProblem.deleted)));
      await store.cleanupDeleted();
      expect((await store.list()).pendingCleanup, 0);
      expect((await store.read('other')).version, 1);
    },
  );
  test(
    'route namespace and key do not touch photo queue or another library',
    () async {
      final photo = File('${root.path}/private_photo_queue_v1/keep.enc');
      await photo.parent.create();
      await photo.writeAsString('keep');
      await put();
      await store.delete('route-a', expectedRevision: 1);
      await store.cleanupUnreferenced();
      expect(await photo.readAsString(), 'keep');
      expect(DeviceRouteKeyVault.keyName, isNot(contains('photo_queue')));
    },
  );
  test('unconfirmed/cross-floor walking edges cannot publish', () async {
    final original = document();
    final bad = RouteDocument(
      id: original.id,
      name: original.name,
      buildingId: original.buildingId,
      nodes: original.nodes,
      edges: const [
        RouteSegment('g', 'three', ConnectorMode.walk, confirmed: true),
      ],
    );
    await expectLater(put(doc: bad), throwsA(fails(RouteProblem.invalid)));
    expect((await store.list()).routes, isEmpty);
  });
  test('explicit pruning retains active, verified fallback and draft, with monotonic versions', () async {
    for (var i = 0; i < 4; i++) {
      await put(revision: i);
    }
    await put(revision: 4, active: false, doc: document(draft: true));
    await store.pruneHistory();
    await store.cleanupUnreferenced();
    final entry = (await store.list()).routes.single;
    expect(entry.versions, [3, 4, 5]);
    expect(entry.activeVersion, 4);
    expect(entry.draftVersion, 5);
    expect(entry.rollbackVersions, [3]);
    expect((await revisions()).length, 3);
    await put(revision: entry.revision);
    expect((await store.read('route-a')).version, 6);
  });
}
