import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake only the platform channel: source, controller and widgets remain real.
class RouteNativeFixture {
  static const methods = MethodChannel('hk.pathguide/route_camera');
  static const events = MethodChannel('hk.pathguide/route_camera/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final Uint8List jpeg = File('test/fixtures/route_camera/keyframe-8x4.jpg')
      .readAsBytesSync();
  Map<String, Object?>? current;
  bool delayStart = false, delayCapture = false;
  String stopStatus = 'stopped';
  Completer<Object?>? startReply, captureReply;
  Map<String, Object?>? capturedResponse;
  Map<String, Object?> Function(Map<String, Object?>)? changeCapture;

  void attach() {
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      final args = Map<String, Object?>.from(call.arguments as Map);
      switch (call.method) {
        case 'start':
          current = args;
          if (delayStart) {
            startReply = Completer<Object?>();
            return startReply!.future;
          }
          return {...args, 'status': 'running'};
        case 'stop':
          return {...args, 'status': stopStatus};
        case 'cancelKeyframe':
          return {...args, 'status': 'cancelled'};
        case 'captureKeyframe':
          final response = <String, Object?>{
            'status': 'captured',
            'jpeg': jpeg,
            'width': 8,
            'height': 4,
            'orientation': 'up',
            'byteCount': jpeg.length,
            'sha256': sha256.convert(jpeg).toString(),
            'header': <String, Object?>{
              ...current!,
              'requestId': args['requestId'],
              'startRequestId': current!['requestId'],
              'sequence': 1,
              'captureClockId': 'avcapture-session-clock-a',
              'clockEpoch': 'clock-a',
              'rawTimestampValue': 700000,
              'rawTimestampTimescale': 1000,
              'rawTimestampEpoch': 0,
              'clockMapping': 'coremedia-host',
              'capturedHostSeconds': 99.9,
              'nativeNowHostSeconds': 100.0,
              'ageMs': 100.0,
              'source': 'avfoundation-back-wide',
              'profile': 'route-camera-engineering-v1',
              'walkingValidated': false,
              'mirrored': false,
              'rotationDegrees': 90,
              'rawWidth': 4,
              'rawHeight': 8,
              'uprightWidth': 8,
              'uprightHeight': 4,
            },
          };
          capturedResponse = changeCapture?.call(response) ?? response;
          if (delayCapture) {
            captureReply = Completer<Object?>();
            return captureReply!.future;
          }
          return capturedResponse;
        default:
          return {...args, 'status': 'failed'};
      }
    });
  }

  void sendEvent(String status) {
    ServicesBinding.instance.channelBuffers.push(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        ...current!,
        'status': status,
      }),
      (_) {},
    );
  }

  void detach() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  }
}
