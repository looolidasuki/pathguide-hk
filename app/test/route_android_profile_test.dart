// Android 路線相機／地標特徵的平台配置。
//
// 每個平台只接受自己誠實的來源標記：Android 關鍵幀標 CameraX 與
// elapsedRealtime 時鐘，不能冒充 iOS 的 AVFoundation／CoreMedia，反之亦然；
// 特徵版本與距離閾值也按平台分開，跨平台的特徵不可直接比對。

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/route_memory/route_localizer.dart';
import 'package:pathguide/route_memory/route_observation_source.dart';
import 'package:pathguide/route_memory/route_package.dart';
import 'package:pathguide/route_memory/route_platform_profile.dart';

import 'route_camera_fixture.dart';

Map<String, Object?> _asAndroid(Map<String, Object?> response) {
  final header = Map<String, Object?>.from(response['header'] as Map);
  header
    ..['source'] = 'camerax-back'
    ..['clockMapping'] = 'android-elapsed-realtime'
    ..['captureClockId'] = 'camerax-session-${header['clockEpoch']}';
  return {...response, 'header': header};
}

Future<RouteCaptureStatus> _captureOnce(
  WidgetTester t,
  RouteNativeFixture native,
) async {
  final source = RouteObservationSource(supported: true);
  expect(
    await source.start(routeId: 'route-a', routeVersion: 1),
    RouteCaptureStatus.running,
  );
  final result = (await t.runAsync(source.capture))!;
  await source.stop();
  return result.status;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => RoutePlatform.debugAndroid = null);

  test('host tests keep the iOS contract by default', () {
    expect(RoutePlatform.isAndroid, isFalse);
    expect(RouteLocalizer.featureRevision, 'vision-featureprint-v1');
    expect(RouteLocalizer.maxDistance, 8.0);
    expect(RoutePlatform.camera.source, 'avfoundation-back-wide');
  });

  test('Android selects CameraX provenance and the embedder profile', () {
    RoutePlatform.debugAndroid = true;
    expect(RoutePlatform.captureSupported, isTrue);
    expect(RouteObservationSource().supported, isTrue);
    expect(RoutePlatform.camera.source, 'camerax-back');
    expect(RoutePlatform.camera.clockId('e1'), 'camerax-session-e1');
    expect(
      RouteLocalizer.featureRevision,
      'mediapipe-mobilenet-v3-small-embedder-v1',
    );
    expect(RouteLocalizer.maxDistance, lessThan(2.0));
    expect(RouteLocalizer.minGap, RoutePlatform.feature.duplicateDistance);
    expect(RoutePlatform.feature.ocrRevisions, isNot(contains(2)));
  });

  test('stored views accept each known camera profile only with its clock', () {
    expect(
      RouteCameraProfile.bySource('camerax-back'),
      RouteCameraProfile.camerax,
    );
    expect(
      RouteCameraProfile.bySource('avfoundation-back-wide'),
      RouteCameraProfile.avfoundation,
    );
    expect(RouteCameraProfile.bySource('camera2-front'), isNull);
    expect(
      RouteCameraProfile.camerax.clockMapping,
      isNot(RouteCameraProfile.avfoundation.clockMapping),
    );
  });

  test('captured routes are replayable only with this platform profile', () {
    // 2026-11-22 真機：Android 錄的路線重開時被判 incompatible，因 compatible
    // 仍寫死 iOS 的 vision-featureprint-v1。宿主測試走 iOS 配置所以沒有發現。
    bool ok(String f, String p) =>
        RouteDocument.compatibleRevisions(RouteContentSource.captured, f, p);
    const android = RouteFeatureProfile.androidEmbedder;
    const vision = RouteFeatureProfile.vision;
    RoutePlatform.debugAndroid = true;
    expect(ok(android.featureRevision, android.preprocessRevision), isTrue);
    expect(ok(vision.featureRevision, vision.preprocessRevision), isFalse);
    RoutePlatform.debugAndroid = false;
    expect(ok(vision.featureRevision, vision.preprocessRevision), isTrue);
    expect(ok(android.featureRevision, android.preprocessRevision), isFalse);
    expect(
      RouteDocument.compatibleRevisions(
        RouteContentSource.synthetic,
        'p0-synthetic-v1',
        'none-synthetic',
      ),
      isTrue,
    );
  });

  testWidgets('Android accepts a CameraX keyframe', (t) async {
    RoutePlatform.debugAndroid = true;
    final native = RouteNativeFixture()
      ..changeCapture = _asAndroid
      ..attach();
    addTearDown(native.detach);
    expect(await _captureOnce(t, native), RouteCaptureStatus.captured);
  });

  testWidgets('Android rejects a keyframe labelled as iOS AVFoundation', (
    t,
  ) async {
    RoutePlatform.debugAndroid = true;
    final native = RouteNativeFixture()..attach();
    addTearDown(native.detach);
    expect(await _captureOnce(t, native), RouteCaptureStatus.invalid);
  });

  testWidgets('iOS rejects a keyframe labelled as Android CameraX', (t) async {
    RoutePlatform.debugAndroid = false;
    final native = RouteNativeFixture()
      ..changeCapture = _asAndroid
      ..attach();
    addTearDown(native.detach);
    expect(await _captureOnce(t, native), RouteCaptureStatus.invalid);
  });

  testWidgets('Android rejects a CameraX source with a mismatched clock id', (
    t,
  ) async {
    RoutePlatform.debugAndroid = true;
    final native = RouteNativeFixture()
      ..changeCapture = (r) {
        final android = _asAndroid(r);
        final header = Map<String, Object?>.from(android['header'] as Map)
          ..['captureClockId'] = 'avcapture-session-clock-a';
        return {...android, 'header': header};
      }
      ..attach();
    addTearDown(native.detach);
    expect(await _captureOnce(t, native), RouteCaptureStatus.invalid);
  });
}
