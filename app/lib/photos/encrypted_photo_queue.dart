import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'photo_models.dart';

/// One encrypted file per candidate. All operations are serialized; atomic rename
/// prevents a killed process from leaving a partly written candidate in the queue.
class EncryptedPhotoQueue implements PhotoQueue {
  EncryptedPhotoQueue({
    required this.project,
    Future<Directory> Function()? directory,
    FlutterSecureStorage? storage,
  }) : _directory = directory ?? getApplicationSupportDirectory,
       _storage =
           storage ??
           const FlutterSecureStorage(
             iOptions: IOSOptions(
               accessibility: KeychainAccessibility.unlocked_this_device,
               synchronizable: false,
             ),
           );
  final String project;
  final Future<Directory> Function() _directory;
  final FlutterSecureStorage _storage;
  final _cipher = AesGcm.with256bits();
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<Directory> _dir() async {
    final root = await _directory();
    return Directory('${root.path}/private_photo_queue_v1')
        .create(recursive: true);
  }

  Future<SecretKey> _key() async {
    const name = 'pathguide.photo_queue.aes.v1';
    final value = await _storage.read(key: name);
    if (value != null) return SecretKey(base64Decode(value));
    final key = await _cipher.newSecretKey();
    await _storage.write(
      key: name,
      value: base64Encode(await key.extractBytes()),
    );
    return key;
  }

  String _safe(String id) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw const PhotoFailure('照片識別碼無效。');
    }
    return id;
  }

  @override
  Future<List<QueuedPhoto>> read() => _serial(() async {
    final dir = await _dir();
    final key = await _key();
    final result = <QueuedPhoto>[];
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      if (!entry.path.endsWith('.enc')) {
        await entry.delete();
        continue;
      }
      try {
        final sealed =
            jsonDecode(await entry.readAsString()) as Map<String, dynamic>;
        final bytes = await _cipher.decrypt(
          SecretBox(
            base64Decode(sealed['data'] as String),
            nonce: base64Decode(sealed['nonce'] as String),
            mac: Mac(base64Decode(sealed['mac'] as String)),
          ),
          secretKey: key,
        );
        final v = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        if (v['project'] != project || v['schemaVersion'] != 1) {
          await entry.delete();
          continue;
        }
        final photo = QueuedPhoto(
          id: v['id'] as String,
          uid: v['uid'] as String,
          project: v['project'] as String,
          epoch: v['epoch'] as int,
          createdAt: DateTime.parse(v['createdAt'] as String),
          jpeg: base64Decode(v['jpeg'] as String),
          metadata: Map<String, dynamic>.from(v['metadata'] as Map),
        );
        if (DateTime.now().toUtc().difference(photo.createdAt) >
            const Duration(days: 7)) {
          await entry.delete();
          continue;
        }
        result.add(photo);
      } catch (_) {
        await entry.delete();
      }
    }
    return result;
  });
  @override
  Future<void> put(QueuedPhoto photo) => _serial(() async {
    final dir = await _dir();
    final bytes = utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'id': photo.id,
        'uid': photo.uid,
        'project': photo.project,
        'epoch': photo.epoch,
        'createdAt': photo.createdAt.toIso8601String(),
        'jpeg': base64Encode(photo.jpeg),
        'metadata': photo.metadata,
      }),
    );
    final box = await _cipher.encrypt(bytes, secretKey: await _key());
    final pending = File('${dir.path}/${_safe(photo.id)}.tmp');
    await pending.writeAsString(
      jsonEncode({
        'nonce': base64Encode(box.nonce),
        'mac': base64Encode(box.mac.bytes),
        'data': base64Encode(box.cipherText),
      }),
      flush: true,
    );
    await pending.rename('${dir.path}/${photo.id}.enc');
  });
  @override
  Future<void> remove(String id) => _serial(() async {
    final file = File('${(await _dir()).path}/${_safe(id)}.enc');
    if (await file.exists()) await file.delete();
  });
  @override
  Future<bool> uploadsPaused() => _serial(
    () async =>
        await _storage.read(key: 'pathguide.photo_pause.$project') == 'true',
  );
  @override
  Future<void> pauseUploads(bool paused) => _serial(
    () => _storage.write(
      key: 'pathguide.photo_pause.$project',
      value: paused.toString(),
    ),
  );
  @override
  Future<void> clear() => _serial(() async {
    final dir = await _dir();
    await for (final file in dir.list()) {
      await file.delete(recursive: true);
    }
  });
}
