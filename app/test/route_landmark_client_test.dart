import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:pathguide/route_memory/route_landmark_client.dart';
import 'package:pathguide/route_memory/route_observation_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hk.pathguide/route_landmark');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'analysis binds the image hash and versions to returned feature bytes',
    () async {
      final image = File('test/fixtures/route_camera/keyframe-8x4.jpg')
          .readAsBytesSync();
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = Map<String, Object?>.from(call.arguments as Map);
        final feature = Uint8List.fromList([1, 2, 3]);
        return {
          ...args,
          'status': 'ok',
          'feature': feature,
          'featureSha': sha256.convert(feature).toString(),
          'text': <String>[],
          'ocrRevision': 3,
          'languages': ['en-US'],
          'manualFloorConfirmationRequired': true,
        };
      });
      final c = RouteLandmarkClient();
      final value = await c.analyze(RouteKeyframe(image, 8, 4, const {}));
      expect(value.feature, [1, 2, 3]);
      expect(value.imageSha, sha256.convert(image).toString());
      c.dispose();
    },
  );
  test(
    'cancel rejects late response and binds cancel to exact active identity',
    () async {
      final gate = Completer<Object?>();
      final entered = Completer<void>();
      String? active, cancelled;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final a = Map<String, Object?>.from(call.arguments as Map);
        if (call.method == 'cancel') {
          cancelled = a['requestId'] as String;
          return null;
        }
        active = a['requestId'] as String;
        entered.complete();
        return gate.future;
      });
      final c = RouteLandmarkClient();
      final pending = c.compare(Uint8List.fromList([1]), [
        Uint8List.fromList([2]),
      ]);
      final check = expectLater(
        pending,
        throwsA(
          isA<LandmarkFailure>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await entered.future;
      await c.cancel();
      expect(cancelled, active);
      gate.complete({'requestId': active});
      await check;
      c.dispose();
    },
  );
  test(
    'malformed and partial distance vectors cannot produce a match',
    () async {
      final c = RouteLandmarkClient();
      for (final distances in [
        <Object>[],
        <Object>[-1],
        <Object>[double.nan],
        <Object>[1, 2],
      ]) {
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => {
            ...Map<String, Object?>.from(call.arguments as Map),
            'status': 'ok',
            'distances': distances,
          },
        );
        await expectLater(
          c.compare(Uint8List.fromList([1]), [
            Uint8List.fromList([2]),
          ]),
          throwsA(isA<LandmarkFailure>()),
        );
      }
      c.dispose();
    },
  );
  test(
    'wrong response identity and unsupported revision are rejected',
    () async {
      final c = RouteLandmarkClient();
      for (final change in [
        {'requestId': 'another'},
        {'featureRevision': 'unknown'},
        {'inputSha': 'wrong'},
      ]) {
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => {
            ...Map<String, Object?>.from(call.arguments as Map),
            'status': 'ok',
            'distances': [0],
            ...change,
          },
        );
        await expectLater(
          c.compare(Uint8List.fromList([1]), [
            Uint8List.fromList([2]),
          ]),
          throwsA(isA<LandmarkFailure>()),
        );
      }
      c.dispose();
    },
  );
  test(
    'cancel acknowledgement cannot block lifecycle shutdown indefinitely',
    () async {
      final entered = Completer<void>(),
          reply = Completer<Object?>(),
          cancelReply = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'cancel') return cancelReply.future;
        entered.complete();
        return reply.future;
      });
      final c = RouteLandmarkClient();
      final pending = c.compare(Uint8List.fromList([1]), [
        Uint8List.fromList([2]),
      ]);
      final checked = expectLater(pending, throwsA(isA<LandmarkFailure>()));
      await entered.future;
      await c.cancel().timeout(const Duration(seconds: 1));
      reply.complete(null);
      await checked;
      cancelReply.complete(null);
      c.dispose();
    },
  );
}
