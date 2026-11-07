import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'route_package.dart';
import 'route_file_policy.dart';

abstract interface class RouteKeyVault {
  Future<List<int>?> read();
  Future<void> write(List<int> bytes);
}

class DeviceRouteKeyVault implements RouteKeyVault {
  static const keyName = 'pathguide.route_memory.library.aes.v1';
  static const _probeKey = 'pathguide.route_memory.probe.aes.v1';
  DeviceRouteKeyVault() : _key = keyName;
  DeviceRouteKeyVault.probe() : _key = _probeKey;
  final String _key;
  Future<void> deleteProbeKey() async {
    if (_key != _probeKey) throw StateError('Not a probe vault');
    await _storage.delete(key: _key);
  }

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
    ),
  );
  @override
  Future<List<int>?> read() async {
    final value = await _storage.read(key: _key);
    return value == null ? null : base64Decode(value);
  }

  @override
  Future<void> write(List<int> bytes) =>
      _storage.write(key: _key, value: base64Encode(bytes));
}

class RouteStoreLimits {
  const RouteStoreLimits({
    this.libraryBytes = 256 * 1024 * 1024,
    this.routeBytes = 64 * 1024 * 1024,
    this.viewsPerNode = RouteMediaBounds.viewsPerNode,
    this.viewsPerRoute = RouteMediaBounds.viewsPerRoute,
    this.documentBytes = 256 * 1024,
    this.versionsPerRoute = 8,
  });
  final int libraryBytes,
      routeBytes,
      documentBytes,
      versionsPerRoute,
      viewsPerNode,
      viewsPerRoute;
}

class _RouteActor {
  Future<void> tail = Future.value();
  final Map<String, int> routeEpoch = {};
  Future<T> run<T>(Future<T> Function() action) {
    final next = tail.then((_) => action());
    tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}

class RouteWriteToken {
  RouteWriteToken._(this._owner, this.id, this._epoch, this._routeEpoch);
  final EncryptedRouteStore _owner;
  final String id;
  final int _epoch, _routeEpoch;
}

/// One route-library owner on the main isolate. Instances on that isolate share
/// a path-scoped actor; an advisory OS lock rejects another process. Do not use
/// independent writers in other isolates (POSIX locks are process-scoped).
class EncryptedRouteStore {
  EncryptedRouteStore._(
    this.directory,
    this._vault,
    this.limits,
    this._hook,
    this._files,
  ) : _actor = _actors.putIfAbsent(directory.path, _RouteActor.new);
  static final Map<String, _RouteActor> _actors = {};
  final Directory directory;
  final RouteKeyVault _vault;
  final RouteFilePolicy? _files;
  final RouteStoreLimits limits;
  final Future<void> Function(String)? _hook;
  final _RouteActor _actor;
  int _epoch = 0;
  final _cipher = AesGcm.with256bits();
  static const _scope = 'pathguide/device-local/routes/v1';

  static Future<EncryptedRouteStore> open({
    Directory? root,
    RouteKeyVault? vault,
    RouteFilePolicy? filePolicy,
    RouteStoreLimits limits = const RouteStoreLimits(),
    Future<void> Function(String)? checkpoint,
  }) async {
    try {
      final policy =
          filePolicy ??
          (root == null && Platform.isIOS
              ? await RouteFilePolicy.open()
              : null);
      final base =
          root ??
          (policy == null
              ? await getApplicationSupportDirectory()
              : policy.directory.parent);
      final dir =
          policy?.directory ??
          await Directory('${base.path}/route_memory_v1')
              .create(recursive: true);
      return EncryptedRouteStore._(
        Directory(await dir.resolveSymbolicLinks()),
        vault ?? DeviceRouteKeyVault(),
        limits,
        checkpoint,
        policy,
      );
    } catch (_) {
      throw const RouteStoreFailure(RouteProblem.io);
    }
  }

  Future<void> _writeFile(File file, List<int> bytes) async {
    if (_files != null) {
      await _files.write(file, bytes);
    } else {
      await file.writeAsBytes(bytes, flush: true);
    }
  }

  Future<void> _renameFile(File source, String destination) async {
    if (_files != null) {
      await _files.rename(source, destination);
    } else {
      await source.rename(destination);
    }
  }

  Future<Directory> _createDirectory(Directory dir) async {
    if (_files != null) {
      await _files.createDirectory(dir);
      return dir;
    }
    return dir.create();
  }

  RouteWriteToken capture(String id) =>
      RouteWriteToken._(this, id, _epoch, _actor.routeEpoch[id] ?? 0);
  void cancelPending() => _epoch++;
  void _guard(RouteWriteToken token) {
    if (!identical(token._owner, this) ||
        token._epoch != _epoch ||
        token._routeEpoch != (_actor.routeEpoch[token.id] ?? 0)) {
      throw const RouteStoreFailure(RouteProblem.cancelled);
    }
  }

  Future<void> _step(String name) async {
    await _hook?.call(name);
  }

  String _sha(List<int> bytes) => hashes.sha256.convert(bytes).toString();
  String _random() => List.generate(
    16,
    (_) => Random.secure().nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  Directory _routeDir(String id) =>
      Directory('${directory.path}/${_sha(utf8.encode(id))}');
  File get _catalogFile => File('${directory.path}/catalog.enc');

  Future<T> _locked<T>(Future<T> Function(SecretKey) action) =>
      _actor.run(() async {
        RandomAccessFile? lock;
        try {
          lock = await File('${directory.path}/.lock')
              .open(mode: FileMode.append);
          try {
            await lock.lock(FileLock.exclusive);
          } on FileSystemException {
            throw const RouteStoreFailure(RouteProblem.busy);
          }
          return await action(await _key());
        } on RouteStoreFailure {
          rethrow;
        } catch (_) {
          throw const RouteStoreFailure(RouteProblem.io);
        } finally {
          await lock?.close();
        }
      });

  Future<SecretKey> _key() async {
    try {
      var bytes = await _vault.read();
      if (bytes == null) {
        await for (final f in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (f is File && !f.path.endsWith('/.lock')) {
            throw const RouteStoreFailure(RouteProblem.keyUnavailable);
          }
        }
        bytes = [for (var i = 0; i < 32; i++) Random.secure().nextInt(256)];
        await _vault.write(bytes);
      }
      if (bytes.length != 32) {
        throw const RouteStoreFailure(RouteProblem.keyUnavailable);
      }
      return SecretKey(bytes);
    } catch (_) {
      throw const RouteStoreFailure(RouteProblem.keyUnavailable);
    }
  }

  Future<List<int>> _seal(
    Map<String, dynamic> value,
    SecretKey key,
    String aad,
  ) async {
    return _sealBytes(utf8.encode(jsonEncode(value)), key, aad);
  }

  Future<List<int>> _sealBytes(
    List<int> value,
    SecretKey key,
    String aad,
  ) async {
    final box = await _cipher.encrypt(
      value,
      secretKey: key,
      aad: utf8.encode('$_scope/$aad'),
    );
    return utf8.encode(
      jsonEncode({
        'nonce': base64Encode(box.nonce),
        'data': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      }),
    );
  }

  Future<List<int>> _unsealBytes(File file, SecretKey key, String aad) async {
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() > 2 * 1024 * 1024) {
        throw const FormatException();
      }
      final sealed = jsonDecode(await file.readAsString()) as Map;
      return await _cipher.decrypt(
        SecretBox(
          base64Decode(sealed['data'] as String),
          nonce: base64Decode(sealed['nonce'] as String),
          mac: Mac(base64Decode(sealed['mac'] as String)),
        ),
        secretKey: key,
        aad: utf8.encode('$_scope/$aad'),
      );
    } catch (_) {
      throw const RouteStoreFailure(RouteProblem.corrupt);
    }
  }

  Future<Map<String, dynamic>> _unseal(
    File file,
    SecretKey key,
    String aad,
  ) async {
    try {
      return jsonDecode(utf8.decode(await _unsealBytes(file, key, aad)))
          as Map<String, dynamic>;
    } catch (_) {
      throw const RouteStoreFailure(RouteProblem.corrupt);
    }
  }

  Map<String, dynamic> _empty() => {
    'schema': 1,
    'owner': 'device-local',
    'routes': <String, dynamic>{},
    'deleted': <String, dynamic>{},
  };
  Future<Map<String, dynamic>> _catalog(SecretKey key) async {
    if (!await _catalogFile.exists()) return _empty();
    final cat = await _unseal(_catalogFile, key, 'catalog');
    try {
      if (cat['schema'] != 1 || cat['owner'] != 'device-local') {
        throw const RouteStoreFailure(RouteProblem.incompatible);
      }
      for (final id in (cat['deleted'] as Map).keys) {
        if (!RouteDocument.validId(id as String) ||
            (cat['routes'] as Map).containsKey(id)) {
          throw const FormatException();
        }
      }
      for (final e in (cat['routes'] as Map).entries) {
        final v = e.value as Map;
        if (!RouteDocument.validId(e.key as String) ||
            (v['revision'] as int) < 1 ||
            (v['next'] as int) < 2 ||
            (v['versions'] as Map).isEmpty) {
          throw const FormatException();
        }
        for (final p in ['active', 'draft']) {
          if (v[p] != null && !(v['versions'] as Map).containsKey('${v[p]}')) {
            throw const FormatException();
          }
        }
        for (final info in (v['versions'] as Map).entries) {
          if (int.parse(info.key as String) <= 0 ||
              int.parse(info.key as String) >= v['next'] ||
              !RegExp(r'^[a-f0-9]{32}\.enc$')
                  .hasMatch(info.value['file'] as String) ||
              !RegExp(r'^[a-f0-9]{64}$')
                  .hasMatch(info.value['sha'] as String)) {
            throw const FormatException();
          }
          final media = info.value['media'];
          if (media != null) {
            if (media is! Map ||
                media.length > 2 * RouteMediaBounds.viewsPerRoute) {
              throw const FormatException();
            }
            for (final blob in media.entries) {
              final metadata = blob.value as Map;
              final maxBytes = metadata['kind'] == 'jpeg'
                  ? RouteMediaBounds.imageBytes
                  : RouteMediaBounds.featureBytes;
              if (!CapturedRouteView.validSha(blob.key as String) ||
                  !RegExp(r'^[a-f0-9]{32}\.enc$')
                      .hasMatch(metadata['file'] as String) ||
                  !CapturedRouteView.validSha(metadata['sha'] as String) ||
                  !['jpeg', 'feature'].contains(metadata['kind']) ||
                  metadata['bytes'] is! int ||
                  metadata['bytes'] <= 0 ||
                  metadata['bytes'] > maxBytes) {
                throw const FormatException();
              }
            }
          }
        }
      }
      return cat;
    } on RouteStoreFailure {
      rethrow;
    } catch (_) {
      throw const RouteStoreFailure(RouteProblem.corrupt);
    }
  }

  Future<int> _diskBytes(Directory dir) async {
    if (!await dir.exists()) return 0;
    var bytes = 0;
    await for (final f in dir.list(recursive: true, followLinks: false)) {
      if (f is File) bytes += await f.length();
    }
    return bytes;
  }

  Future<void> _budget(
    int additional, {
    String? routeId,
    int routeAdditional = 0,
    bool maintenance = false,
  }) async {
    // Reserve one maximum-sized catalog transaction so explicit deletion/pruning
    // remains possible when the normal data budget has been reached.
    final reserve = min(2 * 1024 * 1024, limits.libraryBytes ~/ 4);
    if (await _diskBytes(directory) + additional >
            limits.libraryBytes - (maintenance ? 0 : reserve) ||
        (routeId != null &&
            await _diskBytes(_routeDir(routeId)) + routeAdditional >
                limits.routeBytes)) {
      throw const RouteStoreFailure(RouteProblem.capacity);
    }
  }

  Future<void> _commit(
    Map<String, dynamic> cat,
    SecretKey key, {
    RouteWriteToken? token,
    bool deletion = false,
  }) async {
    final bytes = await _seal(cat, key, 'catalog');
    if (bytes.length > 2 * 1024 * 1024) {
      throw const RouteStoreFailure(RouteProblem.capacity);
    }
    await _budget(bytes.length, maintenance: deletion);
    final temp = File('${directory.path}/${_random()}.tmp');
    await _writeFile(temp, bytes);
    await _step('beforeCatalogCommit');
    if (token != null) _guard(token);
    try {
      await _renameFile(temp, _catalogFile.path);
      await _step('afterCatalogCommit');
    } catch (_) {
      throw const RouteStoreFailure(RouteProblem.outcomeUnknown);
    }
  }

  Future<RouteSnapshot> _read(
    String id,
    int version,
    Map entry,
    SecretKey key, {
    Set<String>? collect,
    Map<String, Uint8List>? into,
  }) async {
    final info = entry['versions']['$version'];
    if (info == null) throw const RouteStoreFailure(RouteProblem.notFound);
    final file = File('${_routeDir(id).path}/${info['file']}');
    try {
      if (await file.length() > 2 * 1024 * 1024) {
        throw const RouteStoreFailure(RouteProblem.corrupt);
      }
      if (_sha(await file.readAsBytes()) != info['sha']) {
        throw const RouteStoreFailure(RouteProblem.corrupt);
      }
      final v = await _unseal(file, key, '$id/$version');
      final document = RouteDocument.fromMap(
        v['document'] as Map<String, dynamic>,
      );
      final published = v['published'] as bool;
      if (v['version'] != version ||
          document.id != id ||
          _sha(utf8.encode(jsonEncode(v['document']))) != v['manifestSha'] ||
          (published && !document.complete)) {
        throw const FormatException();
      }
      final references = _references(document);
      final index = (info['media'] ?? const <String, dynamic>{}) as Map;
      if (index.length != references.length ||
          references.keys.any((sha) => !index.containsKey(sha))) {
        throw const RouteStoreFailure(RouteProblem.corrupt);
      }
      for (final ref in references.entries) {
        final payload = await _readBlob(
          id,
          version,
          ref.key,
          ref.value,
          index[ref.key] as Map,
          key,
        );
        if (into != null && (collect == null || collect.contains(ref.key))) {
          into[ref.key] = Uint8List.fromList(payload).asUnmodifiableView();
        }
      }
      return RouteSnapshot(
        document,
        version,
        published,
        v['manifestSha'] as String,
      );
    } on RouteStoreFailure {
      rethrow;
    } catch (_) {
      throw const RouteStoreFailure(RouteProblem.corrupt);
    }
  }

  Future<RouteLibraryListing> list() => _locked((key) async {
    final cat = await _catalog(key);
    final routes = <RouteLibraryEntry>[];
    for (final e in (cat['routes'] as Map).entries) {
      final v = e.value as Map;
      final versions =
          (v['versions'] as Map).keys
              .map((s) => int.parse(s as String))
              .toList()
            ..sort();
      final recover = <int>[];
      var name = '';
      RouteProblem? problem;
      for (final version in versions) {
        try {
          final snapshot = await _read(e.key as String, version, v, key);
          if (snapshot.published &&
              snapshot.document.compatible &&
              version != v['active']) {
            recover.add(version);
          }
          if (version == (v['draft'] ?? v['active'])) {
            name = snapshot.document.name;
          }
          if ((version == v['active'] || version == v['draft']) &&
              !snapshot.document.compatible) {
            problem = RouteProblem.incompatible;
          }
        } on RouteStoreFailure catch (error) {
          if (version == v['active'] || version == v['draft']) {
            problem = error.problem;
          }
        }
      }
      routes.add(
        RouteLibraryEntry(
          id: e.key as String,
          name: name,
          revision: v['revision'] as int,
          versions: versions,
          rollbackVersions: recover,
          activeVersion: v['active'] as int?,
          draftVersion: v['draft'] as int?,
          problem: problem,
        ),
      );
    }
    var pending = 0;
    for (final id in (cat['deleted'] as Map).keys) {
      if (await _routeDir(id as String).exists()) pending++;
    }
    return RouteLibraryListing(routes, pending);
  });

  Future<RouteSnapshot> read(String id, {int? version}) => _locked((key) async {
    final cat = await _catalog(key);
    final entry = cat['routes'][id] as Map?;
    if (entry == null) throw const RouteStoreFailure(RouteProblem.notFound);
    final selected = version ?? entry['active'] ?? entry['draft'];
    return _read(id, selected as int, entry, key);
  });

  Map<String, ({int bytes, int? width, int? height})> _references(
    RouteDocument document,
  ) {
    final refs = <String, ({int bytes, int? width, int? height})>{};
    void add(String sha, int bytes, int? width, int? height) {
      final ref = (bytes: bytes, width: width, height: height);
      if (refs.containsKey(sha) && refs[sha] != ref) {
        throw const RouteStoreFailure(RouteProblem.invalid);
      }
      refs[sha] = ref;
    }

    for (final v in document.views) {
      add(v.imageSha, v.imageBytes, v.width, v.height);
      if (v.featureSha != null) add(v.featureSha!, v.featureBytes!, null, null);
    }
    return refs;
  }

  Future<List<int>> _readBlob(
    String id,
    int version,
    String sha,
    ({int bytes, int? width, int? height}) ref,
    Map info,
    SecretKey key,
  ) async {
    try {
      if (!RegExp(r'^[a-f0-9]{32}\.enc$').hasMatch(info['file'] as String) ||
          info['bytes'] != ref.bytes ||
          info['kind'] != (ref.width == null ? 'feature' : 'jpeg')) {
        throw const FormatException();
      }
      final f = File('${_routeDir(id).path}/${info['file']}');
      if (await FileSystemEntity.type(f.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await f.length() > 2 * 1024 * 1024 ||
          _sha(await f.readAsBytes()) != info['sha']) {
        throw const FormatException();
      }
      final value = await _unsealBytes(f, key, '$id/$version/media/$sha');
      if (value.length != ref.bytes || _sha(value) != sha) {
        throw const FormatException();
      }
      return value;
    } catch (_) {
      throw const RouteStoreFailure(RouteProblem.corrupt);
    }
  }

  /// Verify the version once and retain only requested immutable blobs. This
  /// prevents N individual feature reads from repeating full-image verification.
  Future<Map<String, Uint8List>> readMediaBatch(
    String id,
    int version, {
    Set<String>? hashes,
  }) => _locked((key) async {
    final cat = await _catalog(key), entry = cat['routes'][id] as Map?;
    if (entry == null) throw const RouteStoreFailure(RouteProblem.notFound);
    final values = <String, Uint8List>{};
    await _read(id, version, entry, key, collect: hashes, into: values);
    if (hashes != null && hashes.any((hash) => !values.containsKey(hash))) {
      throw const RouteStoreFailure(RouteProblem.notFound);
    }
    return Map.unmodifiable(values);
  });

  /// Replay is read-only: it never archives a newly observed camera frame.
  Future<List<int>> readMedia(String id, int version, String sha) =>
      _locked((key) async {
        final cat = await _catalog(key);
        final entry = cat['routes'][id] as Map?;
        if (entry == null) throw const RouteStoreFailure(RouteProblem.notFound);
        final snapshot = await _read(id, version, entry, key);
        final ref = _references(snapshot.document)[sha];
        if (ref == null) throw const RouteStoreFailure(RouteProblem.notFound);
        return _readBlob(
          id,
          version,
          sha,
          ref,
          entry['versions']['$version']['media'][sha] as Map,
          key,
        );
      });

  Future<void> _validateImage(List<int> bytes, int width, int height) async {
    if (bytes.length < 4 ||
        bytes[0] != 255 ||
        bytes[1] != 216 ||
        bytes[bytes.length - 2] != 255 ||
        bytes.last != 217) {
      throw const RouteStoreFailure(RouteProblem.invalid);
    }
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        Uint8List.fromList(bytes),
      );
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          if (descriptor.width != width || descriptor.height != height) {
            throw const FormatException();
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } catch (_) {
      throw const RouteStoreFailure(RouteProblem.invalid);
    }
  }

  /// Explicit recording/update only. Caller supplies all referenced payloads;
  /// no capture, automatic replay archiving, or cloud spillover occurs here.
  Future<RouteSnapshot> save(
    RouteDocument document, {
    required RouteWriteToken token,
    required int expectedRevision,
    required bool activate,
    Map<String, List<int>> media = const {},
  }) async {
    document.validate();
    final refs = _references(document);
    if (media.length != refs.length ||
        media.keys.any((sha) => !refs.containsKey(sha))) {
      throw const RouteStoreFailure(RouteProblem.invalid);
    }
    final inputs = <String, Uint8List>{};
    for (final e in media.entries) {
      if (e.value.length != refs[e.key]!.bytes ||
          e.value.any((b) => b < 0 || b > 255)) {
        throw const RouteStoreFailure(RouteProblem.invalid);
      }
      inputs[e.key] = Uint8List.fromList(e.value);
    }
    return _locked((key) async {
      _guard(token);
      if (token.id != document.id || (activate && !document.complete)) {
        throw const RouteStoreFailure(RouteProblem.invalid);
      }
      if (activate && !document.compatible) {
        throw const RouteStoreFailure(RouteProblem.incompatible);
      }
      final perNode = <String, int>{};
      for (final v in document.views) {
        perNode[v.nodeId] = (perNode[v.nodeId] ?? 0) + 1;
      }
      if (document.views.length > limits.viewsPerRoute ||
          perNode.values.any((n) => n > limits.viewsPerNode)) {
        throw const RouteStoreFailure(RouteProblem.capacity);
      }
      for (final e in refs.entries) {
        if (_sha(inputs[e.key]!) != e.key) {
          throw const RouteStoreFailure(RouteProblem.invalid);
        }
        if (e.value.width != null) {
          await _validateImage(inputs[e.key]!, e.value.width!, e.value.height!);
        }
      }
      final cat = await _catalog(key);
      if ((cat['deleted'] as Map).containsKey(document.id)) {
        throw const RouteStoreFailure(RouteProblem.deleted);
      }
      final previous = cat['routes'][document.id] as Map?;
      if ((previous?['revision'] ?? 0) != expectedRevision) {
        throw const RouteStoreFailure(RouteProblem.conflict);
      }
      if (previous != null) {
        final old = await _read(
          document.id,
          (previous['active'] ?? previous['draft']) as int,
          previous,
          key,
        );
        if (old.document.source != document.source) {
          throw const RouteStoreFailure(RouteProblem.incompatible);
        }
      }
      if (((previous?['versions'] as Map?)?.length ?? 0) >=
          limits.versionsPerRoute) {
        throw const RouteStoreFailure(RouteProblem.capacity);
      }
      final version = previous?['next'] as int? ?? 1;
      final doc = document.toMap(),
          docBytes = utf8.encode(jsonEncode(document.toMap()));
      if (docBytes.length > limits.documentBytes) {
        throw const RouteStoreFailure(RouteProblem.capacity);
      }
      final hash = _sha(docBytes);
      final bytes = await _seal(
        {
          'document': doc,
          'version': version,
          'published': activate,
          'manifestSha': hash,
        },
        key,
        '${document.id}/$version',
      );
      final filename = '${_random()}.enc';
      final index = <String, Map<String, Object>>{
        for (final e in refs.entries)
          e.key: {
            'file': '${_random()}.enc',
            'bytes': e.value.bytes,
            'kind': e.value.width == null ? 'feature' : 'jpeg',
          },
      };
      // GCM envelope adds nonce/MAC and base64. Reserve its upper bound before
      // any payload write, including the old catalog plus the replacement temp.
      final mediaBudget = inputs.values.fold<int>(
        0,
        (sum, b) => sum + ((b.length + 2) ~/ 3) * 4 + 128,
      );
      cat['routes'][document.id] = {
        'revision': expectedRevision + 1,
        'next': version + 1,
        'active': activate ? version : previous?['active'],
        'draft': activate ? null : version,
        'versions': {
          ...?previous?['versions'] as Map?,
          '$version': {'file': filename, 'sha': _sha(bytes), 'media': index},
        },
      };
      // Fill cipher SHA values before reserving the exact catalog length. Media
      // SHA strings are fixed width; payloads are sealed one at a time below.
      for (final value in index.values) {
        value['sha'] = '0' * 64;
      }
      final catalogBytes = await _seal(cat, key, 'catalog');
      if (catalogBytes.length > 2 * 1024 * 1024) {
        throw const RouteStoreFailure(RouteProblem.capacity);
      }
      await _budget(
        bytes.length + mediaBudget + catalogBytes.length,
        routeId: document.id,
        routeAdditional: bytes.length + mediaBudget,
      );
      _guard(token);
      final folder = await _createDirectory(_routeDir(document.id));
      for (final e in inputs.entries) {
        final sealed = await _sealBytes(
          e.value,
          key,
          '${document.id}/$version/media/${e.key}',
        );
        index[e.key]!['sha'] = _sha(sealed);
        final temp = File('${folder.path}/${index[e.key]!['file']}.tmp');
        await _writeFile(temp, sealed);
        await _step('afterMediaWrite');
        _guard(token);
        await _renameFile(temp, '${folder.path}/${index[e.key]!['file']}');
      }
      final temp = File('${folder.path}/$filename.tmp');
      await _writeFile(temp, bytes);
      await _step('afterVersionWrite');
      _guard(token);
      await _renameFile(temp, '${folder.path}/$filename');
      await _commit(cat, key, token: token);
      return RouteSnapshot(document, version, activate, hash);
    });
  }

  Future<void> rollback(
    String id,
    int version, {
    required int expectedRevision,
  }) {
    final token = capture(id);
    return _locked((key) async {
      _guard(token);
      final cat = await _catalog(key);
      final e = cat['routes'][id] as Map?;
      if (e == null) throw const RouteStoreFailure(RouteProblem.notFound);
      if (e['revision'] != expectedRevision) {
        throw const RouteStoreFailure(RouteProblem.conflict);
      }
      final snapshot = await _read(id, version, e, key);
      if (!snapshot.published || !snapshot.document.compatible) {
        throw const RouteStoreFailure(RouteProblem.incompatible);
      }
      e['active'] = version;
      e['revision'] = expectedRevision + 1;
      await _commit(cat, key, token: token);
    });
  }

  Future<void> delete(String id, {required int expectedRevision}) {
    _actor.routeEpoch[id] = (_actor.routeEpoch[id] ?? 0) + 1;
    return _locked((key) async {
      final cat = await _catalog(key);
      final e = cat['routes'][id] as Map?;
      if (e == null && !(cat['deleted'] as Map).containsKey(id)) {
        throw const RouteStoreFailure(RouteProblem.notFound);
      }
      if (e != null && e['revision'] != expectedRevision) {
        throw const RouteStoreFailure(RouteProblem.conflict);
      }
      cat['routes'].remove(id);
      cat['deleted'][id] = true;
      await _commit(cat, key, deletion: true);
      try {
        await _step('beforeDeleteCleanup');
        await _removeDir(id);
      } catch (_) {
        throw const RouteStoreFailure(RouteProblem.cleanupPending);
      }
    });
  }

  Future<void> _removeDir(String id) async {
    final dir = _routeDir(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> cleanupDeleted() => _locked((key) async {
    final cat = await _catalog(key);
    for (final id in (cat['deleted'] as Map).keys) {
      await _removeDir(id as String);
    }
  });

  /// User-requested history pruning: retain active, current draft and one
  /// verified compatible published fallback. Never reuses version numbers.
  Future<void> pruneHistory() => _locked((key) async {
    final cat = await _catalog(key);
    var changed = false;
    for (final e in (cat['routes'] as Map).entries) {
      final entry = e.value as Map;
      final keep = <int>{
        if (entry['active'] != null) entry['active'] as int,
        if (entry['draft'] != null) entry['draft'] as int,
      };
      final versions =
          (entry['versions'] as Map).keys
              .map((s) => int.parse(s as String))
              .toList()
            ..sort((a, b) => b.compareTo(a));
      for (final version in versions) {
        if (version == entry['active']) continue;
        try {
          final s = await _read(e.key as String, version, entry, key);
          if (s.published && s.document.compatible) {
            keep.add(version);
            break;
          }
        } on RouteStoreFailure {
          /* Preserve active separately; reject corrupt fallback. */
        }
      }
      final old = entry['versions'] as Map;
      if (old.length != keep.length) {
        entry['versions'] = {for (final v in keep) '$v': old['$v']};
        entry['revision'] = (entry['revision'] as int) + 1;
        changed = true;
      }
    }
    if (changed) await _commit(cat, key, deletion: true);
  });

  /// Explicit maintenance only. Never deletes a referenced corrupt revision.
  Future<void> cleanupUnreferenced() => _locked((key) async {
    final cat = await _catalog(key);
    final keep = <String>{_catalogFile.path, '${directory.path}/.lock'};
    for (final e in (cat['routes'] as Map).entries) {
      for (final info in (e.value['versions'] as Map).values) {
        keep.add('${_routeDir(e.key as String).path}/${info['file']}');
        for (final blob in ((info['media'] ?? const {}) as Map).values) {
          keep.add('${_routeDir(e.key as String).path}/${blob['file']}');
        }
      }
    }
    await for (final f in directory.list(recursive: true, followLinks: false)) {
      if (f is File && !keep.contains(f.path)) await f.delete();
    }
    for (final id in (cat['deleted'] as Map).keys) {
      await _removeDir(id as String);
    }
  });
}
