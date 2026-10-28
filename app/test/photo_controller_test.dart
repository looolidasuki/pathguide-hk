import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pathguide/account/account_controller.dart';
import 'package:pathguide/photos/photo_controller.dart';
import 'package:pathguide/photos/photo_models.dart';
import 'package:pathguide/photos/encrypted_photo_queue.dart';

import 'support/fake_accounts.dart';

class MemoryPhotos implements PhotoQueue {
  final entries = <QueuedPhoto>[];
  bool paused = false;
  @override
  Future<List<QueuedPhoto>> read() async => List.of(entries);
  @override
  Future<void> put(QueuedPhoto p) async {
    entries.removeWhere((v) => v.id == p.id);
    entries.add(p);
  }

  @override
  Future<void> remove(String id) async =>
      entries.removeWhere((v) => v.id == id);
  @override
  Future<void> clear() async => entries.clear();
  @override
  Future<bool> uploadsPaused() async => paused;
  @override
  Future<void> pauseUploads(bool v) async {
    paused = v;
  }
}

class FakePhotos implements PhotoBackend {
  @override
  bool configured = true;
  PhotoConsent consent = const PhotoConsent(enabled: false, epoch: 0);
  bool failUpload = false, failConsent = false;
  Completer<void>? uploadWait;
  final uploaded = <QueuedPhoto>[];
  @override
  Future<PhotoConsent> readConsent(String uid) async => consent;
  @override
  Future<PhotoConsent> setConsent(String uid, bool enabled) async {
    if (failConsent) throw Exception('offline');
    return consent = PhotoConsent(enabled: enabled, epoch: consent.epoch + 1);
  }

  @override
  Future<List<Map<String, dynamic>>> progress(String uid) async => [];
  @override
  Future<void> upload(QueuedPhoto p) async {
    await uploadWait?.future;
    if (failUpload) throw Exception('offline');
    uploaded.add(p);
  }
}

class FakeNetwork implements PhotoNetwork {
  bool wifi = true;
  @override
  Future<bool> wifiAvailable() async => wifi;
}

Future<void> settle() async {
  for (var i = 0; i < 15; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAuth auth;
  late AccountController account;
  late PhotoController photos;
  late FakePhotos backend;
  late MemoryPhotos queue;
  late FakeNetwork network;
  int captures = 0;
  Future<CapturedPhoto?> source(String _) async {
    captures++;
    return CapturedPhoto(
      jpeg: Uint8List.fromList([255, 216, 1, 255, 217]),
      metadata: {
        'width': 720,
        'height': 1280,
        'predictions': [],
        'modelVersion': 'm1',
        'classMapVersion': 'v1',
      },
    );
  }

  setUp(() async {
    auth = FakeAuth()..current = alice;
    final repo = FakeRepository()..profiles.add(alice.uid);
    account = AccountController(
      auth: auth,
      repository: repo,
      cache: MemoryContactCache(),
      dialer: FakeDialer(),
    );
    await settle();
    backend = FakePhotos();
    queue = MemoryPhotos();
    network = FakeNetwork();
    captures = 0;
    photos = PhotoController(
      account: account,
      backend: backend,
      queue: queue,
      network: network,
      project: 'demo',
    );
    await settle();
  });
  tearDown(() async {
    photos.dispose();
    account.dispose();
    await auth.stream.close();
  });
  test(
    'no capture before separate consent, unconfigured cloud or background',
    () async {
      await photos.capture(source);
      expect(captures, 0);
      backend.configured = false;
      await photos.setEnabled(true);
      expect(photos.enabled, false);
      backend.configured = true;
      await photos.setEnabled(true);
      photos.foreground(false);
      await photos.capture(source);
      expect(captures, 0);
    },
  );
  test('manual capture queues one UID-owned candidate and exact duplicate is ignored', () async {
    await photos.setEnabled(true);
    await photos.capture(source);
    await photos.capture(source);
    expect(queue.entries.length, 1);
    expect(queue.entries.single.uid, alice.uid);
    expect(queue.entries.single.metadata['trigger'], 'manual_report');
    expect(backend.uploaded, isEmpty);
  });
  test('Wi-Fi gate, failed upload, retry use same photo identifier', () async {
    await photos.setEnabled(true);
    await photos.capture(source);
    final id = queue.entries.single.id;
    network.wifi = false;
    await photos.uploadPending();
    expect(backend.uploaded, isEmpty);
    network.wifi = true;
    backend.failUpload = true;
    await photos.uploadPending();
    expect(queue.entries.single.id, id);
    backend.failUpload = false;
    await photos.uploadPending();
    expect(queue.entries, isEmpty);
    expect(backend.uploaded.single.id, id);
  });
  test(
    'UID switching clears queue and does not upload previous users candidates',
    () async {
      await photos.setEnabled(true);
      await photos.capture(source);
      auth.switchTo(bob);
      await settle();
      expect(queue.entries, isEmpty);
      expect(photos.count, 0);
      await photos.uploadPending();
      expect(backend.uploaded, isEmpty);
    },
  );
  test('withdrawal stops collection and removes queued data', () async {
    await photos.setEnabled(true);
    await photos.capture(source);
    await photos.setEnabled(false);
    expect(photos.enabled, false);
    expect(queue.entries, isEmpty);
    await photos.capture(source);
    expect(captures, 1);
  });
  test(
    'offline withdrawal stays locally paused even after refresh and restart',
    () async {
      await photos.setEnabled(true);
      backend.failConsent = true;
      await photos.setEnabled(false);
      expect(queue.paused, true);
      await photos.refresh();
      expect(photos.enabled, false);
      photos.dispose();
      photos = PhotoController(
        account: account,
        backend: backend,
        queue: queue,
        network: network,
        project: 'demo',
      );
      await settle();
      expect(photos.enabled, false);
    },
  );
  test('capture finishing after withdrawal cannot be saved', () async {
    await photos.setEnabled(true);
    final result = Completer<CapturedPhoto?>();
    final job = photos.capture((_) => result.future);
    await settle();
    await photos.setEnabled(false);
    result.complete(await source('manual_report'));
    await job;
    expect(queue.entries, isEmpty);
  });
  test(
    'capacity stops native capture without interrupting recognition',
    () async {
      await photos.setEnabled(true);
      for (var i = 0; i < 50; i++) {
        queue.entries.add(
          QueuedPhoto(
            id: i.toString().padLeft(32, '0'),
            uid: alice.uid,
            project: 'demo',
            epoch: photos.epoch,
            createdAt: DateTime.now(),
            jpeg: Uint8List(1),
            metadata: {},
          ),
        );
      }
      await photos.capture(source);
      expect(captures, 0);
      expect(photos.message, contains('已滿'));
    },
  );
  test('automatic capture requires opt-in and respects cooldown', () async {
    await photos.setEnabled(true);
    await photos.capture(source, trigger: 'scene_sample');
    expect(captures, 0);
    photos.setAutomatic(true);
    await photos.capture(source, trigger: 'scene_sample');
    await photos.capture(source, trigger: 'low_confidence');
    expect(captures, 1);
  });
  test(
    'encrypted disk queue roundtrip, expiry and wrong-project cleanup',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('pathguide-queue-');
      try {
        final store = EncryptedPhotoQueue(
          project: 'demo',
          directory: () async => dir,
        );
        final p = QueuedPhoto(
          id: 'a' * 32,
          uid: 'alice',
          project: 'demo',
          epoch: 1,
          createdAt: DateTime.now().toUtc(),
          jpeg: Uint8List.fromList([255, 216, 1, 255, 217]),
          metadata: {'private': 'secret marker'},
        );
        await store.put(p);
        final file = await Directory('${dir.path}/private_photo_queue_v1')
            .list()
            .single;
        expect(
          await File(file.path).readAsString(),
          isNot(contains('secret marker')),
        );
        expect((await store.read()).single.jpeg, p.jpeg);
        final wrong = EncryptedPhotoQueue(
          project: 'other',
          directory: () async => dir,
        );
        expect(await wrong.read(), isEmpty);
        await store.put(
          QueuedPhoto(
            id: 'b' * 32,
            uid: 'alice',
            project: 'demo',
            epoch: 1,
            createdAt: DateTime.now().subtract(const Duration(days: 8)),
            jpeg: p.jpeg,
            metadata: {},
          ),
        );
        expect(await store.read(), isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
