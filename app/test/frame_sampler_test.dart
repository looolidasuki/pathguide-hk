import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pathguide/capture/capture_result.dart';
import 'package:pathguide/capture/frame_sampler.dart';
import 'package:pathguide/vision/platform_contract.dart';
import 'package:pathguide/vision/platform_vision.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FrameSampler', () {
    test('fires immediately then on interval; stop halts further captures',
        () async {
      var calls = 0;
      final sampler = FrameSampler(
        interval: const Duration(milliseconds: 40),
        maxFiles: 50,
        capture: () async {
          calls += 1;
          return CaptureResult(
            ok: true,
            path: null, // skip prune / disk
            width: 1,
            height: 1,
            bytes: 0,
          );
        },
      );

      sampler.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 1, reason: 'immediate first tick');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, greaterThanOrEqualTo(3));
      final atStop = calls;
      sampler.stop();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(calls, atStop, reason: 'no ticks after stop');
      expect(sampler.isRunning, isFalse);
    });

    test('counts only successful saves with a path', () async {
      final dir = Directory.systemTemp.createTempSync('pg_capture_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      var n = 0;
      final sampler = FrameSampler(
        interval: const Duration(days: 1),
        capture: () async {
          n += 1;
          if (n == 1) {
            return const CaptureResult(ok: false, error: 'no frame');
          }
          final f = File('${dir.path}/ok_$n.jpg');
          await f.writeAsBytes(const <int>[0xFF, 0xD8, 0xFF]);
          return CaptureResult(ok: true, path: f.path, bytes: 3);
        },
      );

      sampler.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(sampler.savedCount, 0);

      // Manual second tick via private path: restart after injecting success.
      sampler.stop();
      // Drive two ticks by calling start twice with a capture that succeeds.
      final success = FrameSampler(
        interval: const Duration(days: 1),
        capture: () async {
          final f = File('${dir.path}/s_${DateTime.now().microsecondsSinceEpoch}.jpg');
          await f.writeAsBytes(const <int>[0xFF, 0xD8]);
          return CaptureResult(ok: true, path: f.path, bytes: 2);
        },
      );
      success.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(success.savedCount, 1);
      success.stop();
    });

    test('prunes oldest jpg files beyond maxFiles', () async {
      final dir = Directory.systemTemp.createTempSync('pg_prune_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      for (var i = 0; i < 3; i++) {
        File('${dir.path}/2026010${i}_000000_000.jpg')
            .writeAsBytesSync(const <int>[1, 2, 3]);
      }

      final sampler = FrameSampler(
        interval: const Duration(days: 1),
        maxFiles: 2,
        capture: () async {
          final f = File('${dir.path}/20260109_000000_000.jpg');
          await f.writeAsBytes(const <int>[9]);
          return CaptureResult(ok: true, path: f.path, bytes: 1);
        },
      );
      sampler.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      sampler.stop();

      final left = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jpg'))
          .map((f) => f.uri.pathSegments.last)
          .toList()
        ..sort();
      expect(left.length, 2);
      expect(left.contains('20260100_000000_000.jpg'), isFalse);
    });
  });

  group('PlatformVision.captureFrame', () {
    test('MissingPluginException becomes failed CaptureResult', () async {
      const channel = MethodChannel(kVisionChannel);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      final vision = PlatformVision();
      final result = await vision.captureFrame();
      expect(result.ok, isFalse);
      expect(result.error, isNotNull);
    });

    test('parses successful native reply', () async {
      const channel = MethodChannel(kVisionChannel);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, VisionMethods.captureFrame);
        return <String, Object?>{
          'ok': true,
          'path': '/tmp/x.jpg',
          'width': 720,
          'height': 1280,
          'bytes': 1234,
        };
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final result = await PlatformVision().captureFrame();
      expect(result.ok, isTrue);
      expect(result.path, '/tmp/x.jpg');
      expect(result.width, 720);
      expect(result.height, 1280);
      expect(result.bytes, 1234);
    });
  });
}
