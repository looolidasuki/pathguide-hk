import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'cross_floor_contract.dart';
import 'encrypted_route_store.dart';
import 'route_file_policy.dart';
import 'route_package.dart';

/// Explicit launch-argument engineering harness. It uses only an artificial
/// 8x4 JPEG and opaque test feature bytes in a separate directory and Keychain
/// purpose. No camera/user route/real localization feature is read or created.
Future<void> runRequestedRouteStorageProbe() async {
  if (!Platform.isIOS) return;
  String? phase;
  try {
    phase = await RouteFilePolicy.channel.invokeMethod<String>('probePhase');
  } on MissingPluginException {
    return;
  }
  if (!['write', 'read', 'delete'].contains(phase)) return;
  final report = <String, Object?>{
    'phase': phase,
    'fixtureOnly': true,
    'passed': false,
  };
  final vault = DeviceRouteKeyVault.probe();
  try {
    if (phase == 'write') {
      await RouteFilePolicy.channel.invokeMethod<void>('removeProbe');
      await vault.deleteProbeKey();
    }
    final policy = await RouteFilePolicy.open(probe: true);
    final store = await EncryptedRouteStore.open(
      filePolicy: policy,
      vault: vault,
    );
    final image = base64Decode(
      '/9j/4AAQSkZJRgABAQAASABIAAD/4QBARXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAACKADAAQAAAABAAAABAAAAAD/wAARCAAEAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9sAQwACAgICAgIDAgIDBQMDAwUGBQUFBQYIBgYGBgYICggICAgICAoKCgoKCgoKDAwMDAwMDg4ODg4PDw8PDw8PDw8P/9sAQwECAgIEBAQHBAQHEAsJCxAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ/90ABAAB/9oADAMBAAIRAxEAPwDm6KKK/jc/08P/2Q==',
    );
    final feature = utf8.encode('opaque-storage-probe-feature');
    final imageSha = sha256.convert(image).toString(),
        featureSha = sha256.convert(feature).toString();
    const id = 'storage-engineering-probe';
    if (phase == 'write') {
      final doc = RouteDocument(
        id: id,
        name: 'Engineering fixture only',
        buildingId: 'fixture',
        source: RouteContentSource.captured,
        featureRevision: 'vision-featureprint-v1',
        preprocessRevision: 'upright-jpeg-v1',
        nodes: const [
          RoutePoint(
            'start',
            '樣例起點',
            'Fixture start',
            floor: FloorRef('fixture', 'g', 'G'),
          ),
          RoutePoint(
            'end',
            '樣例終點',
            'Fixture end',
            floor: FloorRef('fixture', 'g', 'G'),
          ),
        ],
        edges: const [
          RouteSegment('start', 'end', ConnectorMode.walk, confirmed: true),
        ],
        views: [
          for (final node in ['start', 'end'])
            CapturedRouteView(
              nodeId: node,
              viewId: 'front',
              imageSha: imageSha,
              imageBytes: image.length,
              width: 8,
              height: 4,
              featureSha: featureSha,
              featureBytes: feature.length,
              savedAtUtc: DateTime.now().toUtc().toIso8601String(),
              observation: {
                'routeId': id,
                'routeVersion': 1,
                'session': 'engineering-fixture',
                'generation': 1,
                'sequence': 1,
                'source': 'avfoundation-back-wide',
                'profile': 'route-camera-engineering-v1',
                'walkingValidated': false,
                'mirrored': false,
                'clockMapping': 'coremedia-host',
                'rotationDegrees': 0,
                'clockEpoch': 'fixture',
                'captureClockId': 'avcapture-session-fixture',
                'capturedHostSeconds': 1.0,
              },
            ),
        ],
      );
      await store.save(
        doc,
        token: store.capture(id),
        expectedRevision: 0,
        activate: true,
        media: {imageSha: image, featureSha: feature},
      );
    }
    final before = await policy.inspect();
    report['filePolicy'] = before;
    if (before['allProtected'] != true ||
        before['allExcludedFromBackup'] != true) {
      throw StateError('file_policy');
    }
    final key = await RouteFilePolicy.channel.invokeMapMethod<String, Object?>(
      'probeKeyAttributes',
    );
    report['keyPolicy'] = key;
    if (key?['found'] != true ||
        key?['thisDeviceOnlyWhenUnlocked'] != true ||
        key?['synchronizable'] != false) {
      throw StateError('key_policy');
    }
    if ((await store.read(id)).version != 1 ||
        sha256.convert(await store.readMedia(id, 1, imageSha)).toString() !=
            imageSha ||
        sha256.convert(await store.readMedia(id, 1, featureSha)).toString() !=
            featureSha) {
      throw StateError('reopen');
    }
    report['reopenedAndVerified'] = true;
    if (phase == 'delete') {
      await store.delete(id, expectedRevision: 1);
      await store.cleanupUnreferenced();
      final after = await policy.inspect();
      report['afterDelete'] = after;
      if ((await store.list()).routes.isNotEmpty || after['files'] != 2) {
        throw StateError('delete');
      }
      await policy.removeProbe();
      await vault.deleteProbeKey();
      final removed = await RouteFilePolicy.channel
          .invokeMapMethod<String, Object?>('probeKeyAttributes');
      report['probeDirectoryRemoved'] = !await policy.directory.exists();
      report['probeKeyRemoved'] = removed?['found'] == false;
      if (report['probeDirectoryRemoved'] != true ||
          report['probeKeyRemoved'] != true) {
        throw StateError('probe_cleanup');
      }
    }
    report['passed'] = true;
  } catch (error) {
    report['problem'] = error is RouteStoreFailure
        ? error.problem.name
        : error is StateError
        ? error.message
        : 'storage_check_failed';
  }
  await RouteFilePolicy.channel.invokeMethod<void>('probeReport', report);
}
