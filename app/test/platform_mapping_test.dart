import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/vision/platform_contract.dart';
import 'package:pathguide/vision/platform_vision.dart';
import 'package:pathguide/vision/vision_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();
  final binding = TestDefaultBinaryMessengerBinding.instance;

  for (final phase in ['startPreview', 'modelDir', 'loadModel']) {
    test('disposal during $phase cannot load or enable an old model', () async {
      final entered = Completer<void>(), pending = Completer<Object?>();
      final calls = <String>[];
      final messenger = binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel(kVisionChannel), (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == phase) {
          entered.complete();
          return pending.future;
        }
        return switch (call.method) {
          'startPreview' => {'started': true},
          'modelDir' => '/models',
          'fileSize' => -1,
          'loadModel' => {'loaded': true, 'classes': 10, 'inputSize': 640},
          _ => null,
        };
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel(kVisionChannel),
          null,
        ),
      );
      final source = PlatformVision();
      final job = source.initialize();
      await entered.future;
      await source.dispose();
      pending.complete(switch (phase) {
        'startPreview' => {'started': true},
        'modelDir' => '/models',
        _ => {'loaded': true, 'classes': 10, 'inputSize': 640},
      });
      expect((await job).ok, isFalse);
      expect(source.isReady, isFalse);
      expect(calls.where((c) => c == 'release'), hasLength(1));
      expect(
        calls.where((c) => c == 'loadModel'),
        hasLength(phase == 'loadModel' ? 1 : 0),
      );
    });
  }

  for (final nativeClasses in [9, 3, 10]) {
    test(
      'startup gates frames and validates native classes=$nativeClasses',
      () async {
        final enteredLoad = Completer<void>();
        final loaded = Completer<Object?>();
        final loadMaps = <Object?>[];
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel(kVisionChannel),
          (call) async {
            switch (call.method) {
              case 'startPreview':
                return {'started': true};
              case 'modelDir':
                return '/models';
              case 'fileSize':
                return -1;
              case 'loadModel':
                loadMaps.add((call.arguments as Map)['classIds']);
                enteredLoad.complete();
                return loaded.future;
              default:
                return null;
            }
          },
        );
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel(kFrameChannel),
          (_) async => null,
        );
        final source = nativeClasses == 10
            ? PlatformVision()
            : PlatformVision(
                modelAssetKey: legacyModelAssetKey,
                modelManifestKey: legacyModelManifestKey,
              );
        final frames = <VisionFrame>[];
        final subscription = source.frames.listen(frames.add);
        Future<void> emit() async {
          ServicesBinding.instance.channelBuffers.push(
            kFrameChannel,
            codec.encodeSuccessEnvelope({
              'detections': [
                for (final id in [0, 5, 11, 6])
                  {
                    'id': id,
                    'score': 0.9,
                    'cx': 0.5,
                    'cy': 0.5,
                    'w': 0.2,
                    'h': 0.2,
                  },
              ],
              'frameWidth': 1280,
              'frameHeight': 720,
            }),
            (_) {},
          );
          await Future<void>.delayed(Duration.zero);
        }

        try {
          final initializing = source.initialize();
          await enteredLoad.future;
          await emit();
          expect(
            frames,
            isEmpty,
            reason: 'Unvalidated local IDs must never reach labels or speech',
          );
          expect(loadMaps, [
            nativeClasses == 10
                ? [6, 11, 7, 8, 9, 24, 1, 49, 26, 18]
                : [11, 7, 8, 50, 49, 6, 9, 51, 24],
          ]);
          loaded.complete({
            'loaded': true,
            'classes': nativeClasses,
            'inputSize': 640,
          });
          final status = await initializing;
          expect(status.ok, nativeClasses != 3);
          expect(source.isReady, status.ok);
          await emit();
          if (status.ok) {
            expect(frames.single.detections.map((d) => d.id), [11, 6]);
          } else {
            expect(
              frames,
              isEmpty,
              reason: 'A mismatched model must remain silent',
            );
          }
          await source.dispose();
          final count = frames.length;
          await emit();
          expect(frames.length, count);
        } finally {
          await subscription.cancel();
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel(kVisionChannel),
            null,
          );
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel(kFrameChannel),
            null,
          );
        }
      },
    );
  }
}
