import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:pathguide/route_memory/encrypted_route_store.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/route_package.dart';

Map<String, dynamic> capturedManifest() => {
  'schemaVersion': 2,
  'source': 'captured',
  'direction': 'recorded',
  'id': 'captured-a',
  'name': 'Recorded route',
  'buildingId': 'building',
  'featureRevision': 'vision-featureprint-v1',
  'preprocessRevision': 'upright-jpeg-v1',
  'nodes': [
    {
      'id': 'g',
      'zh': '地下',
      'en': 'Ground',
      'floor': {'building': 'building', 'id': 'g', 'label': 'G'},
    },
  ],
  'edges': [],
  'views': [
    {
      'nodeId': 'g',
      'viewId': 'front',
      'imageSha': sha256.convert(utf8.encode('image')).toString(),
      'imageBytes': 5,
      'width': 2,
      'height': 2,
      'featureSha': sha256.convert(utf8.encode('feature')).toString(),
      'featureBytes': 7,
      'savedAtUtc': '2026-11-05T00:00:00.000Z',
      'observation': {
        'routeId': 'captured-a',
        'routeVersion': 1,
        'session': 'session',
        'generation': 1,
        'sequence': 1,
        'source': 'avfoundation-back-wide',
        'profile': 'route-camera-engineering-v1',
        'walkingValidated': false,
        'mirrored': false,
        'clockMapping': 'coremedia-host',
        'rotationDegrees': 90,
        'clockEpoch': 'epoch',
        'captureClockId': 'avcapture-session-epoch',
        'capturedHostSeconds': 5.0,
      },
    },
  ],
};

class TestVault implements RouteKeyVault {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> write(List<int> bytes) async {
    key = List.of(bytes);
  }
}

Map<String, List<int>> capturedMedia() => {
  sha256
      .convert(
        File('test/fixtures/route_camera/keyframe-8x4.jpg').readAsBytesSync(),
      )
      .toString(): File('test/fixtures/route_camera/keyframe-8x4.jpg')
      .readAsBytesSync(),
  sha256.convert(utf8.encode('feature')).toString(): utf8.encode('feature'),
};
RouteDocument capturedDocument() {
  final v = jsonDecode(jsonEncode(capturedManifest())) as Map<String, dynamic>;
  final image = File('test/fixtures/route_camera/keyframe-8x4.jpg')
      .readAsBytesSync();
  final first = v['views'][0] as Map<String, dynamic>;
  first.addAll({
    'imageSha': sha256.convert(image).toString(),
    'imageBytes': image.length,
    'width': 8,
    'height': 4,
  });
  (v['nodes'] as List).add({...v['nodes'][0] as Map, 'id': 'end'});
  (v['edges'] as List).add({
    'from': 'g',
    'to': 'end',
    'mode': 'walk',
    'connector': null,
    'confirmed': true,
  });
  (v['views'] as List).add({...first, 'nodeId': 'end'});
  return RouteDocument.fromMap(v);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory testRoot;
  late TestVault testVault;
  late EncryptedRouteStore testStore;
  setUp(() async {
    testRoot = await Directory.systemTemp.createTemp('p3a-store-');
    testVault = TestVault();
    testStore = await EncryptedRouteStore.open(
      root: testRoot,
      vault: testVault,
    );
  });
  tearDown(() async {
    await testRoot.delete(recursive: true);
  });
  Future<RouteSnapshot> put({
    EncryptedRouteStore? using,
    int revision = 0,
    RouteDocument? document,
    bool activate = true,
    Map<String, List<int>>? media,
  }) {
    final store = using ?? testStore, doc = document ?? capturedDocument();
    return store.save(
      doc,
      token: store.capture(doc.id),
      expectedRevision: revision,
      activate: activate,
      media: media ?? capturedMedia(),
    );
  }

  Matcher failure(RouteProblem problem) =>
      isA<RouteStoreFailure>().having((e) => e.problem, 'problem', problem);

  test('batch feature read returns only requested immutable blobs and still verifies images', () async {
    final saved = await put();
    final doc = capturedDocument();
    final feature = doc.views.first.featureSha!;
    final values = await testStore.readMediaBatch(
      doc.id,
      saved.version,
      hashes: {feature},
    );
    expect(values.keys, [feature]);
    expect(() => values[feature]![0] = 0, throwsUnsupportedError);
    final all = await testStore.readMediaBatch(doc.id, saved.version);
    expect(all.length, 2);
    await expectLater(
      testStore.readMediaBatch(doc.id, saved.version, hashes: {'missing'}),
      throwsA(isA<RouteStoreFailure>()),
    );
    final files = await testRoot
        .list(recursive: true)
        .where(
          (f) =>
              f is File &&
              f.path.endsWith('.enc') &&
              !f.path.endsWith('/catalog.enc'),
        )
        .toList();
    expect(files, isNotEmpty);
    await File(files.first.path).writeAsBytes([1]);
    await expectLater(
      testStore.readMediaBatch(doc.id, saved.version, hashes: {feature}),
      throwsA(isA<RouteStoreFailure>()),
    );
  });
  test('format caps reject oversized image/feature references and wrong capture flags', () {
    final original = jsonDecode(
      jsonEncode(capturedDocument().toMap()),
    ) as Map<String, dynamic>;
    for (final change in [
      {'imageBytes': 524289},
      {'featureBytes': 65537},
      {
        'observation': {
          ...original['views'][0]['observation'] as Map,
          'walkingValidated': true,
        },
      },
    ]) {
      final v = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
      (v['views'][0] as Map).addAll(change);
      expect(
        () => RouteDocument.fromMap(v),
        throwsA(failure(RouteProblem.invalid)),
      );
    }
  });

  test(
    'missing, forged and unexpected payloads cannot replace the stable version',
    () async {
      await put();
      final missing = capturedMedia()
        ..remove(capturedDocument().views.first.imageSha);
      final forged = capturedMedia();
      forged[capturedDocument().views.first.imageSha] = List.filled(
        capturedDocument().views.first.imageBytes,
        0,
      );
      for (final media in [
        missing,
        forged,
        {
          ...capturedMedia(),
          'extra': [1],
        },
      ]) {
        await expectLater(
          put(revision: 1, media: media),
          throwsA(failure(RouteProblem.invalid)),
        );
      }
      expect((await testStore.read('captured-a')).version, 1);
    },
  );

  test(
    'JPEG dimensions are validated independently from the manifest',
    () async {
      final map = capturedDocument().toMap();
      final v = jsonDecode(jsonEncode(map)) as Map<String, dynamic>;
      for (final view in v['views']) {
        view['width'] = 7;
      }
      await expectLater(
        put(document: RouteDocument.fromMap(v)),
        throwsA(failure(RouteProblem.invalid)),
      );
      expect((await testStore.list()).routes, isEmpty);
    },
  );

  test('draft and history bytes count toward route and library quotas; active stays stable', () async {
    await put();
    for (final limits in [
      const RouteStoreLimits(routeBytes: 1),
      const RouteStoreLimits(libraryBytes: 100),
      const RouteStoreLimits(viewsPerRoute: 1),
    ]) {
      final limited = await EncryptedRouteStore.open(
        root: testRoot,
        vault: testVault,
        limits: limits,
      );
      await expectLater(
        put(using: limited, revision: 1, activate: false),
        throwsA(failure(RouteProblem.capacity)),
      );
      expect((await testStore.read('captured-a')).version, 1);
      expect((await testStore.list()).routes.single.versions, [1]);
    }
  });

  test(
    'synthetic routes cannot become captured routes under the same identity',
    () async {
      final map = jsonDecode(
        jsonEncode(capturedDocument().toMap()),
      ) as Map<String, dynamic>;
      map['schemaVersion'] = 1;
      map['source'] = 'synthetic';
      map.remove('views');
      map['featureRevision'] = 'p0-synthetic-v1';
      map['preprocessRevision'] = 'none-synthetic';
      final doc = RouteDocument.fromMap(map);
      await testStore.save(
        doc,
        token: testStore.capture(doc.id),
        expectedRevision: 0,
        activate: true,
      );
      await expectLater(
        put(revision: 1),
        throwsA(failure(RouteProblem.incompatible)),
      );
      expect(
        (await testStore.read(doc.id)).document.toMap()['source'],
        'synthetic',
      );
    },
  );

  for (final cancel in ['pause', 'delete']) {
    test('$cancel cancels media waiting before catalog publication', () async {
      await put();
      final reached = Completer<void>(), release = Completer<void>();
      final slow = await EncryptedRouteStore.open(
        root: testRoot,
        vault: testVault,
        checkpoint: (step) async {
          if (step == 'afterMediaWrite') {
            reached.complete();
            await release.future;
          }
        },
      );
      final pending = expectLater(
        put(using: slow, revision: 1),
        throwsA(failure(RouteProblem.cancelled)),
      );
      await reached.future.timeout(const Duration(seconds: 3));
      Future<void>? deleting;
      if (cancel == 'pause') {
        slow.cancelPending();
      } else {
        deleting = testStore.delete('captured-a', expectedRevision: 1);
      }
      release.complete();
      await pending;
      if (deleting != null) await deleting;
      await testStore.cleanupUnreferenced();
      if (cancel == 'pause') {
        expect((await testStore.read('captured-a')).version, 1);
      } else {
        expect((await testStore.list()).routes, isEmpty);
        expect(
          (await testStore.directory
                  .list(recursive: true)
                  .where((f) => f is File)
                  .toList())
              .length,
          2,
        );
        await expectLater(put(), throwsA(failure(RouteProblem.deleted)));
      }
    });
  }

  test('a crash after media write preserves old pointer; explicit cleanup removes orphans', () async {
    await put();
    final filesBefore = await testStore.directory
        .list(recursive: true)
        .where((f) => f is File)
        .length;
    final broken = await EncryptedRouteStore.open(
      root: testRoot,
      vault: testVault,
      checkpoint: (step) async {
        if (step == 'afterMediaWrite') {
          throw const FileSystemException('disk error');
        }
      },
    );
    await expectLater(
      put(using: broken, revision: 1),
      throwsA(failure(RouteProblem.io)),
    );
    expect((await testStore.read('captured-a')).version, 1);
    expect(
      await testStore.directory
          .list(recursive: true)
          .where((f) => f is File)
          .length,
      greaterThan(filesBefore),
    );
    await testStore.cleanupUnreferenced();
    expect(
      await testStore.directory
          .list(recursive: true)
          .where((f) => f is File)
          .length,
      filesBefore,
    );
  });

  test('tampered image blocks latest version; explicit rollback recovers and delete removes all media', () async {
    await put();
    final before = (await testStore.directory.list(recursive: true).toList())
        .map((f) => f.path)
        .toSet();
    await put(revision: 1);
    File? damaged;
    await for (final f in testStore.directory.list(recursive: true)) {
      if (f is! File || before.contains(f.path) || !f.path.endsWith('.enc')) {
        continue;
      }
      final envelope = jsonDecode(await f.readAsString()) as Map;
      if (base64Decode(envelope['data'] as String).length ==
          capturedDocument().views.first.imageBytes) {
        damaged = f;
        break;
      }
    }
    expect(damaged, isNotNull);
    await damaged!.writeAsString('broken');
    await expectLater(
      testStore.read('captured-a'),
      throwsA(failure(RouteProblem.corrupt)),
    );
    await testStore.cleanupUnreferenced();
    expect(
      await damaged.exists(),
      isTrue,
      reason: 'referenced corrupt files are retained',
    );
    await testStore.rollback('captured-a', 1, expectedRevision: 2);
    expect((await testStore.read('captured-a')).version, 1);
    await testStore.delete('captured-a', expectedRevision: 3);
    expect((await testStore.list()).routes, isEmpty);
    expect(
      await testStore.directory
          .list(recursive: true)
          .where((f) => f is File)
          .length,
      2,
    );
  });

  test(
    'input buffers are copied before an asynchronous save can observe mutation',
    () async {
      final data = capturedMedia();
      final pending = put(media: data);
      data[capturedDocument().views.first.imageSha]![0] = 0;
      await pending;
      expect(
        await testStore.readMedia(
          'captured-a',
          1,
          capturedDocument().views.first.imageSha,
        ),
        capturedMedia()[capturedDocument().views.first.imageSha],
      );
    },
  );

  test('captured image and feature archive reopens with bound hashes and encrypted bytes', () async {
    final root = await Directory.systemTemp.createTemp('p3a-');
    addTearDown(() => root.delete(recursive: true));
    final vault = TestVault();
    var store = await EncryptedRouteStore.open(root: root, vault: vault);
    final doc = capturedDocument();
    await store.save(
      doc,
      token: store.capture(doc.id),
      expectedRevision: 0,
      activate: true,
      media: capturedMedia(),
    );
    store = await EncryptedRouteStore.open(root: root, vault: vault);
    final reopened = await store.read(doc.id);
    expect(reopened.document.toMap(), doc.toMap());
    for (final entry in capturedMedia().entries) {
      expect(await store.readMedia(doc.id, 1, entry.key), entry.value);
    }
    final before = {
      await for (final f in store.directory.list(recursive: true))
        if (f is File) f.path: await f.readAsBytes(),
    };
    await store.read(doc.id);
    await store.readMedia(doc.id, 1, doc.views.first.imageSha);
    final after = {
      await for (final f in store.directory.list(recursive: true))
        if (f is File) f.path: await f.readAsBytes(),
    };
    expect(
      after,
      before,
      reason: 'ordinary reads/replay never add a frame archive',
    );
    for (final file in before.values) {
      expect(
        utf8.decode(file, allowMalformed: true),
        isNot(contains('Recorded route')),
      );
    }
  });
  test('captured schema roundtrips image and feature references without relabeling v1', () {
    final manifest = capturedManifest();
    expect(RouteDocument.fromMap(manifest).toMap(), manifest);
    final synthetic = Map<String, dynamic>.from(manifest)
      ..['schemaVersion'] = 1
      ..['source'] = 'synthetic'
      ..remove('views')
      ..['featureRevision'] = 'p0-synthetic-v1'
      ..['preprocessRevision'] = 'none-synthetic';
    expect(RouteDocument.fromMap(synthetic).toMap(), synthetic);
  });
}
