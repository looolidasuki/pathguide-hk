import 'dart:convert';
import 'dart:typed_data';

import 'route_package.dart' show RouteDocument, RouteProblem, RouteStoreFailure;

/// Frozen engineering limits, including drafts and historical versions at the
/// store level. They are storage limits, not validated walking profiles.
abstract final class RouteMediaBounds {
  static const imageBytes = 512 * 1024;
  static const featureBytes = 64 * 1024;
  static const viewsPerNode = 4;
  static const viewsPerRoute = 64;
  static const audioNoteBytes = 1024 * 1024;
  static const audioBytesPerRoute = 4 * 1024 * 1024;
  static const audioNoteSeconds = 10;
}

/// The iPhone recorder emits a bounded, mono 16-bit PCM WAV in memory.
class RouteAudioNote {
  RouteAudioNote._(this.bytes);

  factory RouteAudioNote.fromBytes(Uint8List bytes) {
    if (bytes.length < 46 || bytes.length > RouteMediaBounds.audioNoteBytes) {
      throw const RouteStoreFailure(RouteProblem.invalid);
    }
    final header = ByteData.sublistView(bytes);
    int word(int at) => header.getUint16(at, Endian.little);
    int size(int at) => header.getUint32(at, Endian.little);
    bool tag(int at, int expected) =>
        header.getUint32(at, Endian.big) == expected;
    final rate = size(24), payload = bytes.length - 44;
    if (!tag(0, 0x52494646) || // RIFF
        !tag(8, 0x57415645) || // WAVE
        !tag(12, 0x666d7420) || // fmt
        !tag(36, 0x64617461) || // data
        size(4) != bytes.length - 8 ||
        size(16) != 16 ||
        word(20) != 1 ||
        word(22) != 1 ||
        word(32) != 2 ||
        word(34) != 16 ||
        rate < 8000 ||
        rate > 96000 ||
        size(28) != rate * 2 ||
        size(40) != payload ||
        payload.isOdd ||
        payload < rate ~/ 2 ||
        payload > rate * 2 * RouteMediaBounds.audioNoteSeconds) {
      throw const RouteStoreFailure(RouteProblem.invalid);
    }
    return RouteAudioNote._(Uint8List.fromList(bytes).asUnmodifiableView());
  }

  factory RouteAudioNote.fromBase64(String encoded) {
    if (encoded.length > ((RouteMediaBounds.audioNoteBytes + 2) ~/ 3) * 4) {
      throw const RouteStoreFailure(RouteProblem.invalid);
    }
    final note = RouteAudioNote.fromBytes(base64Decode(encoded));
    if (note.encoded != encoded) {
      throw const RouteStoreFailure(RouteProblem.invalid);
    }
    return note;
  }

  final Uint8List bytes;
  late final String encoded = base64Encode(bytes);
}

class CapturedRouteView {
  CapturedRouteView({
    required this.nodeId,
    required this.viewId,
    required this.imageSha,
    required this.imageBytes,
    required this.width,
    required this.height,
    required this.savedAtUtc,
    required Map<String, Object?> observation,
    this.featureSha,
    this.featureBytes,
  }) : observation = Map.unmodifiable(observation);
  final String nodeId, viewId, imageSha, savedAtUtc;
  final int imageBytes, width, height;
  final String? featureSha;
  final int? featureBytes;

  /// Only flat native capture provenance is accepted; no mutable nested data.
  final Map<String, Object?> observation;
  static bool validSha(String value) =>
      RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

  void validate(String routeId) {
    final time = DateTime.tryParse(savedAtUtc);
    if (!RouteDocument.validId(nodeId) ||
        !RouteDocument.validId(viewId) ||
        !validSha(imageSha) ||
        imageBytes <= 0 ||
        imageBytes > RouteMediaBounds.imageBytes ||
        width <= 0 ||
        height <= 0 ||
        width > 1280 ||
        height > 1280 ||
        time == null ||
        !time.isUtc ||
        savedAtUtc.length > 40 ||
        (featureSha == null) != (featureBytes == null) ||
        (featureSha != null &&
            (!validSha(featureSha!) ||
                featureBytes! <= 0 ||
                featureBytes! > RouteMediaBounds.featureBytes))) {
      throw const RouteStoreFailure(RouteProblem.invalid);
    }
    if (observation.length > 40 ||
        observation.values.any(
          (v) => v is! String && v is! bool && v is! num && v != null,
        ) ||
        observation.values.whereType<num>().any((v) => !v.isFinite) ||
        utf8.encode(jsonEncode(observation)).length > 4096 ||
        observation['routeId'] != routeId ||
        observation['source'] != 'avfoundation-back-wide' ||
        observation['profile'] != 'route-camera-engineering-v1' ||
        observation['walkingValidated'] != false ||
        observation['mirrored'] != false ||
        observation['clockMapping'] != 'coremedia-host' ||
        ![0, 90, 180, 270].contains(observation['rotationDegrees'])) {
      throw const RouteStoreFailure(RouteProblem.invalid);
    }
    for (final key in ['routeVersion', 'generation', 'sequence']) {
      if (observation[key] is! int || (observation[key] as int) <= 0) {
        throw const RouteStoreFailure(RouteProblem.invalid);
      }
    }
    for (final key in ['session', 'clockEpoch', 'captureClockId']) {
      if (observation[key] is! String ||
          (observation[key] as String).isEmpty ||
          (observation[key] as String).length > 200) {
        throw const RouteStoreFailure(RouteProblem.invalid);
      }
    }
    if (observation['captureClockId'] !=
            'avcapture-session-${observation['clockEpoch']}' ||
        observation['capturedHostSeconds'] is! num ||
        (observation['capturedHostSeconds'] as num) < 0) {
      throw const RouteStoreFailure(RouteProblem.invalid);
    }
  }

  Map<String, Object?> toMap() => {
    'nodeId': nodeId,
    'viewId': viewId,
    'imageSha': imageSha,
    'imageBytes': imageBytes,
    'width': width,
    'height': height,
    'featureSha': featureSha,
    'featureBytes': featureBytes,
    'savedAtUtc': savedAtUtc,
    'observation': observation,
  };
  factory CapturedRouteView.fromMap(Map<String, dynamic> v) =>
      CapturedRouteView(
        nodeId: v['nodeId'] as String,
        viewId: v['viewId'] as String,
        imageSha: v['imageSha'] as String,
        imageBytes: v['imageBytes'] as int,
        width: v['width'] as int,
        height: v['height'] as int,
        featureSha: v['featureSha'] as String?,
        featureBytes: v['featureBytes'] as int?,
        savedAtUtc: v['savedAtUtc'] as String,
        observation: Map<String, Object?>.from(v['observation'] as Map),
      );
}
