import 'dart:io';

import 'package:flutter/services.dart';

/// The native filesystem seam enforces iOS file protection and backup exclusion
/// at creation and again after every rename. Injected test roots use real host IO.
class RouteFilePolicy {
  RouteFilePolicy._(this.scope, this.directory);
  static const channel = MethodChannel('hk.pathguide/route_storage');
  final String scope;
  final Directory directory;

  static Future<RouteFilePolicy> open({bool probe = false}) async {
    final scope = probe ? 'probe' : 'library';
    final path = await channel.invokeMethod<String>('prepare', {
      'scope': scope,
    });
    if (path == null) {
      throw const FileSystemException('Route storage unavailable');
    }
    return RouteFilePolicy._(
      scope,
      Directory(await Directory(path).resolveSymbolicLinks()),
    );
  }

  String _relative(String path) {
    final prefix = '${directory.path}/';
    if (!path.startsWith(prefix)) {
      throw const FileSystemException('Outside route storage');
    }
    return path.substring(prefix.length);
  }

  Future<void> createDirectory(Directory dir) => channel.invokeMethod<void>(
    'mkdir',
    {'scope': scope, 'path': _relative(dir.path)},
  );
  Future<void> write(File file, List<int> bytes) =>
      channel.invokeMethod<void>('write', {
        'scope': scope,
        'path': _relative(file.path),
        'bytes': Uint8List.fromList(bytes),
      });
  Future<void> rename(File source, String destination) =>
      channel.invokeMethod<void>('move', {
        'scope': scope,
        'from': _relative(source.path),
        'to': _relative(destination),
      });
  Future<Map<String, Object?>> inspect() async =>
      await channel.invokeMapMethod<String, Object?>('inspect', {
        'scope': scope,
      }) ??
      const {};
  Future<void> removeProbe() async {
    if (scope != 'probe') throw StateError('Only probe storage can be removed');
    await channel.invokeMethod<void>('removeProbe');
  }
}
