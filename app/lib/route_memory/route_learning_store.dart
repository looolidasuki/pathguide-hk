import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'encrypted_route_store.dart';
import 'route_file_policy.dart';
import 'route_platform_profile.dart';

/// Local evidence only. Verification does not authorize training or alter routes.
enum LearningReview { pending, verified, needsInformation, rejected }

class LearningStoreFailure implements Exception {
  const LearningStoreFailure(this.code);
  final String code;
}

class _LearningActor {
  Future<void> tail = Future.value();
  Future<T> run<T>(Future<T> Function() action) {
    final next = tail.then((_) => action());
    tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}

/// One main-isolate owner; path-scoped serialization plus a process lock.
/// Separate key, directory and AAD from the stable route library.
class RouteLearningStore {
  RouteLearningStore._(
    this.directory,
    this.vault,
    this.policy,
    this.clock,
    this.checkpoint,
  ) : _actor = _actors.putIfAbsent(directory.path, _LearningActor.new);
  static final Map<String, _LearningActor> _actors = {};
  final Directory directory;
  final RouteKeyVault vault;
  final RouteFilePolicy? policy;
  final DateTime Function() clock;
  final Future<void> Function()? checkpoint;
  final _LearningActor _actor;
  final _cipher = AesGcm.with256bits();
  int _epoch = 0;
  static const retention = Duration(days: 7);
  static const maxCandidates = 48, maxPerRoute = 24, maxPerTrip = 12;
  static const diskLimit = 64 * 1024 * 1024;
  static final _id = RegExp(r'^[a-zA-Z0-9_-]{1,120}$');
  static String _random() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  static String _sha(List<int> value) => sha256.convert(value).toString();
  File get _catalog => File('${directory.path}/catalog.enc');
  void cancelPending() => _epoch++;

  static Future<RouteLearningStore> open({
    Directory? root,
    RouteKeyVault? vault,
    DateTime Function()? clock,
    Future<void> Function()? checkpoint,
  }) async {
    // iOS：原生 route_storage 通道負責檔案保護及備份排除。
    // Android：與路線庫相同放在 App 私有目錄（allowBackup=false），
    // 沒有 route_storage 通道。
    final policy = root == null && !RoutePlatform.isAndroid
        ? await RouteFilePolicy.open(learning: true)
        : null;
    final base =
        root ??
        (policy == null ? await getApplicationSupportDirectory() : null);
    final dir =
        policy?.directory ??
        await Directory('${base!.path}/route_learning_v1')
            .create(recursive: true);
    return RouteLearningStore._(
      Directory(await dir.resolveSymbolicLinks()),
      vault ?? DeviceRouteKeyVault.learning(),
      policy,
      clock ?? DateTime.now,
      checkpoint,
    );
  }

  /// 本機路標候選只在有原生支援的平台開放（iOS；Android 以 Platform 判斷，
  /// 主機測試的 defaultTargetPlatform 不會誤開）。其他平台回傳 null。
  static Future<RouteLearningStore> Function()? get platformOpener =>
      !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.iOS ||
              RoutePlatform.isAndroid)
      ? RouteLearningStore.open
      : null;

  Never _fail(String code) => throw LearningStoreFailure(code);
  void _valid(bool value) {
    if (!value) _fail('invalid');
  }

  Future<T> _run<T>(Future<T> Function(SecretKey, int) action) {
    final epoch = _epoch;
    return _actor.run(() async {
      if (epoch != _epoch) _fail('cancelled');
      final lock = await File('${directory.path}/.lock')
          .open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.exclusive);
        var key = await vault.read();
        if (key == null) {
          // ★ 用路徑的**最後一段**判斷，不要比對 '/.lock'（同 encrypted_route_store）：
          //   Windows 的 path 用反斜線，鎖檔會被誤判成「有資料但沒有金鑰」。
          if (await directory.list().any(
            (e) =>
                e.uri.pathSegments.where((s) => s.isNotEmpty).last != '.lock',
          )) {
            _fail('keyUnavailable');
          }
          key = [for (var i = 0; i < 32; i++) Random.secure().nextInt(256)];
          await vault.write(key);
        }
        if (key.length != 32) _fail('keyUnavailable');
        return await action(SecretKey(key), epoch);
      } on LearningStoreFailure {
        rethrow;
      } catch (_) {
        _fail('io');
      } finally {
        await lock.close();
      }
    });
  }

  Future<List<int>> _seal(
    Map<String, dynamic> value,
    SecretKey key,
    String aad,
  ) async {
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(value)),
      secretKey: key,
      aad: utf8.encode('pathguide/learning/v1/$aad'),
    );
    return box.concatenation();
  }

  Future<Map<String, dynamic>> _read(
    File file,
    SecretKey key,
    String aad,
  ) async {
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() > 2 * 1024 * 1024) {
        _fail('corrupt');
      }
      final bytes = await file.readAsBytes();
      final plain = await _cipher.decrypt(
        SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16),
        secretKey: key,
        aad: utf8.encode('pathguide/learning/v1/$aad'),
      );
      return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    } catch (_) {
      _fail('corrupt');
    }
  }

  Future<Map<String, dynamic>> _load(SecretKey key) async {
    if (!await _catalog.exists()) {
      return {
        'schema': 1,
        'records': <String, dynamic>{},
        'deleted': <String>[],
      };
    }
    final value = await _read(_catalog, key, 'catalog');
    if (value['schema'] != 1 ||
        value['records'] is! Map ||
        value['deleted'] is! List ||
        (value['records'] as Map).length > maxCandidates) {
      _fail('corrupt');
    }
    for (final e in (value['records'] as Map).entries) {
      final m = e.value;
      if (!_id.hasMatch(e.key as String) ||
          m is! Map ||
          m['file'] is! String ||
          !RegExp(r'^[a-f0-9]{64}/[a-f0-9]{32}\.enc$').hasMatch(m['file']) ||
          m['revision'] is! int ||
          m['expires'] is! int ||
          m['route'] is! String ||
          m['trip'] is! String) {
        _fail('corrupt');
      }
    }
    return value;
  }

  Future<void> _write(File file, List<int> bytes) async {
    if (policy != null) {
      await policy!.write(file, bytes);
    } else {
      await file.writeAsBytes(bytes, flush: true);
    }
  }

  Future<void> _move(File from, String to) async {
    if (policy != null) {
      await policy!.rename(from, to);
    } else {
      await from.rename(to);
    }
  }

  Future<void> _commit(
    Map<String, dynamic> cat,
    SecretKey key,
    int epoch, {
    bool Function()? isCurrent,
  }) async {
    final bytes = await _seal(cat, key, 'catalog');
    if (bytes.length > 256 * 1024) _fail('capacity');
    final temp = File('${directory.path}/${_random()}.tmp');
    await _write(temp, bytes);
    try {
      await checkpoint?.call();
      if (epoch != _epoch || isCurrent?.call() == false) _fail('cancelled');
      await _move(temp, _catalog.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<int> _diskBytes() async {
    var size = 0;
    await for (final f in directory.list(recursive: true, followLinks: false)) {
      if (f is Link) _fail('corrupt');
      if (f is File) size += await f.length();
    }
    return size;
  }

  Future<void> _saveRecord(
    Map<String, dynamic> cat,
    String id,
    Map<String, dynamic> data,
    SecretKey key,
    int epoch, {
    bool Function()? isCurrent,
  }) async {
    final records = cat['records'] as Map;
    final old = records[id] as Map?;
    final folder = _sha(utf8.encode(data['route'] as String));
    final dir = Directory('${directory.path}/$folder');
    if (!await dir.exists()) {
      if (policy != null) {
        await policy!.createDirectory(dir);
      } else {
        await dir.create();
      }
    }
    final path = '$folder/${_random()}.enc';
    final sealed = await _seal(data, key, 'record/$id');
    if (sealed.length > 2 * 1024 * 1024 ||
        await _diskBytes() + sealed.length + 512 * 1024 > diskLimit) {
      _fail('capacity');
    }
    final temp = File('${directory.path}/$path.tmp');
    final file = File('${directory.path}/$path');
    await _write(temp, sealed);
    await _move(temp, file.path);
    records[id] = {
      'file': path,
      'sha': _sha(sealed),
      'revision': data['revision'],
      'route': data['route'],
      'trip': data['trip'],
      'expires': data['expires'],
      'state': data['state'],
    };
    try {
      await _commit(cat, key, epoch, isCurrent: isCurrent);
    } catch (_) {
      // A unique unreferenced blob never becomes a candidate after cancellation.
      if (await file.exists()) await file.delete();
      rethrow;
    }
    if (old != null) {
      final previous = File('${directory.path}/${old['file']}');
      if (await previous.exists()) await previous.delete();
    }
  }

  Future<String> add({
    required String routeId,
    required int routeVersion,
    required String tripId,
    required String session,
    required int sequence,
    required String requestedNode,
    required String result,
    String? predictedNode,
    required Uint8List jpeg,
    required Uint8List feature,
    required String featureProfile,
    required String preprocessProfile,
    bool Function()? isCurrent,
  }) => _run((key, epoch) async {
    if (isCurrent?.call() == false) _fail('cancelled');
    _valid(
      [routeId, tripId, session, requestedNode].every(_id.hasMatch) &&
          routeVersion > 0 &&
          sequence >= 0 &&
          (predictedNode == null || _id.hasMatch(predictedNode)) &&
          jpeg.length >= 4 &&
          jpeg.length <= 512 * 1024 &&
          jpeg[0] == 255 &&
          jpeg[1] == 216 &&
          jpeg[jpeg.length - 2] == 255 &&
          jpeg.last == 217 &&
          feature.isNotEmpty &&
          feature.length <= 65536 &&
          featureProfile.isNotEmpty &&
          featureProfile.length <= 120 &&
          preprocessProfile.isNotEmpty &&
          preprocessProfile.length <= 120 &&
          [
            'candidate',
            'unknown',
            'ambiguous',
            'conflicting',
            'confirmed',
            'wrongNode',
            'stale',
          ].contains(result),
    );
    final cat = await _load(key), records = cat['records'] as Map;
    if ((cat['deleted'] as List).contains(routeId)) _fail('deleted');
    await _removeExpired(cat, key, epoch);
    if (records.length >= maxCandidates ||
        records.values.where((m) => m['route'] == routeId).length >=
            maxPerRoute ||
        records.values.where((m) => m['trip'] == tripId).length >= maxPerTrip) {
      _fail('capacity');
    }
    final imageSha = _sha(jpeg);
    for (final id in records.keys) {
      final m = records[id] as Map;
      if (m['trip'] == tripId) {
        final previous = await _record(cat, id as String, key);
        if (previous['imageSha'] == imageSha ||
            (previous['session'] == session &&
                previous['sequence'] == sequence)) {
          _fail('duplicate');
        }
      }
    }
    final id = _random(), now = clock().toUtc();
    await _saveRecord(
      cat,
      id,
      {
        'id': id,
        'route': routeId,
        'routeVersion': routeVersion,
        'trip': tripId,
        'session': session,
        'sequence': sequence,
        'requestedNode': requestedNode,
        'prediction': result,
        'predictedNode': predictedNode,
        'featureProfile': featureProfile,
        'preprocessProfile': preprocessProfile,
        'created': now.millisecondsSinceEpoch,
        'expires': now.add(retention).millisecondsSinceEpoch,
        'imageSha': imageSha,
        'featureSha': _sha(feature),
        'jpeg': base64Encode(jpeg),
        'feature': base64Encode(feature),
        'revision': 0,
        'state': LearningReview.pending.name,
        'reviews': [],
      },
      key,
      epoch,
      isCurrent: isCurrent,
    );
    return id;
  });

  Future<Map<String, dynamic>> _record(
    Map<String, dynamic> cat,
    String id,
    SecretKey key,
  ) async {
    final m = (cat['records'] as Map)[id] as Map?;
    if (m == null) _fail('missing');
    if ((m['expires'] as int) <= clock().millisecondsSinceEpoch) {
      _fail('expired');
    }
    final file = File('${directory.path}/${m['file']}');
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > 2 * 1024 * 1024) {
      _fail('corrupt');
    }
    if (_sha(await file.readAsBytes()) != m['sha']) _fail('corrupt');
    final data = await _read(file, key, 'record/$id');
    if (data['id'] != id ||
        data['revision'] != m['revision'] ||
        data['route'] != m['route'] ||
        data['trip'] != m['trip'] ||
        data['expires'] != m['expires'] ||
        data['state'] != m['state'] ||
        _sha(base64Decode(data['jpeg'] as String)) != data['imageSha'] ||
        _sha(base64Decode(data['feature'] as String)) != data['featureSha']) {
      _fail('corrupt');
    }
    return data;
  }

  Future<Map<String, dynamic>> read(String id) =>
      _run((key, _) async => _record(await _load(key), id, key));

  Future<List<String>> list({String? routeId}) => _run((key, _) async {
    final cat = await _load(key);
    return [
      for (final e in (cat['records'] as Map).entries)
        if ((routeId == null || e.value['route'] == routeId) &&
            (e.value['expires'] as int) > clock().millisecondsSinceEpoch)
          e.key as String,
    ];
  });

  /// Local reviewer assertion, not server authorization or independent truth.
  Future<void> review(
    String id, {
    required int expectedRevision,
    required LearningReview decision,
    required String reviewer,
    required String reason,
    String? node,
    String? floor,
    bool directionChecked = false,
    bool exitChecked = false,
    bool Function()? isCurrent,
  }) => _run((key, epoch) async {
    _valid(
      reviewer.trim().isNotEmpty &&
          reviewer.length <= 120 &&
          reason.trim().length >= 5 &&
          reason.length <= 500 &&
          decision != LearningReview.pending,
    );
    if (decision == LearningReview.verified) {
      _valid(
        node != null &&
            _id.hasMatch(node) &&
            floor != null &&
            floor.trim().isNotEmpty &&
            floor.length <= 40 &&
            directionChecked &&
            exitChecked,
      );
    }
    final cat = await _load(key), data = await _record(cat, id, key);
    if (data['revision'] != expectedRevision) _fail('conflict');
    final history = data['reviews'] as List;
    if (history.length >= 16) _fail('capacity');
    history.add({
      'reviewer': reviewer.trim(),
      'reason': reason.trim(),
      'decision': decision.name,
      'node': node,
      'floor': floor,
      'directionChecked': directionChecked,
      'exitChecked': exitChecked,
      'at': clock().toUtc().millisecondsSinceEpoch,
    });
    data['revision'] = expectedRevision + 1;
    data['state'] = decision.name;
    await _saveRecord(cat, id, data, key, epoch, isCurrent: isCurrent);
  });

  /// Tombstone commits first, so a late queued add cannot restore a deleted route.
  Future<void> deleteRoute(String routeId) {
    cancelPending();
    return _run((key, epoch) async {
      final cat = await _load(key);
      final deleted = cat['deleted'] as List;
      if (!deleted.contains(routeId)) deleted.add(routeId);
      await _removeRecords(
        cat,
        key,
        epoch,
        (m) => m['route'] == routeId,
        commitEvenIfEmpty: true,
      );
      await _cleanupOrphans(cat);
    });
  }

  Future<void> deleteTrip(String tripId) => _run((key, epoch) async {
    final cat = await _load(key);
    await _removeRecords(cat, key, epoch, (m) => m['trip'] == tripId);
    await _cleanupOrphans(cat);
  });

  Future<void> deleteCandidate(String id) => _run((key, epoch) async {
    final cat = await _load(key);
    final record = (cat['records'] as Map)[id];
    await _removeRecords(cat, key, epoch, (m) => identical(m, record));
    await _cleanupOrphans(cat);
  });

  Future<void> _removeRecords(
    Map<String, dynamic> cat,
    SecretKey key,
    int epoch,
    bool Function(Map) matches, {
    bool commitEvenIfEmpty = false,
  }) async {
    final records = cat['records'] as Map;
    final removed = records.entries
        .where((e) => matches(e.value as Map))
        .toList();
    if (removed.isEmpty && !commitEvenIfEmpty) return;
    for (final entry in removed) {
      records.remove(entry.key);
    }
    await _commit(cat, key, epoch);
    for (final entry in removed) {
      final file = File('${directory.path}/${entry.value['file']}');
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _removeExpired(
    Map<String, dynamic> cat,
    SecretKey key,
    int epoch,
  ) {
    final now = clock().millisecondsSinceEpoch;
    return _removeRecords(cat, key, epoch, (m) => (m['expires'] as int) <= now);
  }

  /// Explicit expiry/orphan maintenance; never touches the stable route library.
  Future<void> cleanup() => _run((key, epoch) async {
    final cat = await _load(key);
    await _removeExpired(cat, key, epoch);
    await _cleanupOrphans(cat);
  });

  Future<void> _cleanupOrphans(Map<String, dynamic> cat) async {
    final keep = {
      _catalog.path,
      '${directory.path}/.lock',
      for (final m in (cat['records'] as Map).values)
        '${directory.path}/${m['file']}',
    };
    // ★ keep 用 '/' 拼路徑，但 Windows 的 Directory.list 回傳反斜線路徑；
    //   直接比對會把要保留的紀錄與 .lock 都當孤兒刪掉。POSIX（Android／iOS）上這是 no-op。
    final keepNative = {
      for (final k in keep) k.replaceAll('/', Platform.pathSeparator),
    };
    await for (final f in directory.list(recursive: true, followLinks: false)) {
      if (f is File && !keepNative.contains(f.path)) await f.delete();
    }
  }
}
