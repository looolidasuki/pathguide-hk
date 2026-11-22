import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Native camera provenance for a route keyframe. Each platform reports its own
/// honest source and clock labels; a keyframe never borrows another platform's.
@immutable
class RouteCameraProfile {
  const RouteCameraProfile._(this.source, this.clockMapping, this.clockPrefix);

  /// iOS: AVFoundation back wide camera, CoreMedia host clock.
  static const avfoundation = RouteCameraProfile._(
    'avfoundation-back-wide',
    'coremedia-host',
    'avcapture-session-',
  );

  /// Android: CameraX back camera, SystemClock.elapsedRealtime clock base.
  static const camerax = RouteCameraProfile._(
    'camerax-back',
    'android-elapsed-realtime',
    'camerax-session-',
  );

  static const known = [avfoundation, camerax];

  final String source, clockMapping, clockPrefix;
  static const profile = 'route-camera-engineering-v1';

  String clockId(String epoch) => '$clockPrefix$epoch';

  static RouteCameraProfile? bySource(Object? source) {
    for (final p in known) {
      if (p.source == source) return p;
    }
    return null;
  }
}

/// Landmark descriptor profile. Distances are only comparable within one
/// profile; a route recorded with another profile reports incompatible.
///
/// Thresholds are engineering candidates, not probabilities, and do not
/// authorize automatic walking instructions.
@immutable
class RouteFeatureProfile {
  const RouteFeatureProfile._({
    required this.featureRevision,
    required this.preprocessRevision,
    required this.maxDistance,
    required this.minGap,
    required this.duplicateDistance,
    required this.ocrRevisions,
  });

  /// iOS Apple Vision feature print (VNGenerateImageFeaturePrintRequest r1).
  static const vision = RouteFeatureProfile._(
    featureRevision: 'vision-featureprint-v1',
    preprocessRevision: 'upright-jpeg-v1',
    maxDistance: 8.0,
    minGap: 2.0,
    duplicateDistance: 2.0,
    ocrRevisions: {2, 3},
  );

  /// Android MediaPipe MobileNetV3-small image embedder on LiteRT; cosine
  /// distance (1 - cos) of L2-normalised 1024-d embeddings, range 0..2.
  ///
  /// 2026-11-23 provisional thresholds from a desk check only (same view with
  /// 8% crop and 15% darker: mean 0.16, worst 0.21; different photos mean
  /// 0.70). Not field-calibrated; route images must recalibrate them.
  static const androidEmbedder = RouteFeatureProfile._(
    featureRevision: 'mediapipe-mobilenet-v3-small-embedder-v1',
    preprocessRevision: 'upright-jpeg-224-rgb-pm1-v1',
    maxDistance: 0.35,
    minGap: 0.09,
    duplicateDistance: 0.09,
    ocrRevisions: {1},
  );

  final String featureRevision, preprocessRevision;
  final double maxDistance, minGap, duplicateDistance;
  final Set<int> ocrRevisions;
}

/// Platform selection for native route capture. Uses the real host OS, so
/// host unit tests keep the iOS contract unless a test opts into Android.
abstract final class RoutePlatform {
  @visibleForTesting
  static bool? debugAndroid;

  static bool get isAndroid => debugAndroid ?? (!kIsWeb && Platform.isAndroid);

  /// Native route camera and landmark plugins exist on iOS and Android.
  static bool get captureSupported =>
      debugAndroid ?? (!kIsWeb && (Platform.isIOS || Platform.isAndroid));

  static RouteCameraProfile get camera =>
      isAndroid ? RouteCameraProfile.camerax : RouteCameraProfile.avfoundation;

  static RouteFeatureProfile get feature => isAndroid
      ? RouteFeatureProfile.androidEmbedder
      : RouteFeatureProfile.vision;
}
