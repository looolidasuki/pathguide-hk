import 'dart:async';

import 'package:pathguide/scene/scene_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/platform/app_attestation.dart';

void main() {
  test(
    'cancellation during attestation prevents a later paid upload',
    () async {
      final activation = Completer<bool>();
      var current = true, uploads = 0;
      final work = () async {
        await awaitSceneAttestation(activation.future, () => current);
        uploads++;
      }();
      final result = expectLater(
        work,
        throwsA(isA<SceneFailure>().having((e) => e.code, 'code', 'cancelled')),
      );
      current = false;
      activation.complete(true);
      await result;
      expect(uploads, 0);
    },
  );
  test('failed attestation is reported distinctly before any upload', () async {
    await expectLater(
      awaitSceneAttestation(Future.value(false), () => true),
      throwsA(
        isA<SceneFailure>().having(
          (e) => e.code,
          'code',
          'app-check-unavailable',
        ),
      ),
    );
  });
  test('release cannot select a debug provider even with trial flags and credential', () {
    expect(
      appAttestationMode(
        release: true,
        debugRequested: true,
        trial: true,
        credentialConfigured: true,
      ),
      AppAttestationMode.device,
    );
  });
  test('private trial fails closed when its credential is missing', () {
    expect(
      appAttestationMode(
        release: false,
        debugRequested: true,
        trial: true,
        credentialConfigured: false,
      ),
      AppAttestationMode.unavailable,
    );
  });
  test('engineering profile can select a registered debug credential', () {
    expect(
      appAttestationMode(
        release: false,
        debugRequested: true,
        trial: true,
        credentialConfigured: true,
      ),
      AppAttestationMode.debug,
    );
  });
  test('ordinary builds keep device verification unless debug explicitly requested', () {
    expect(
      appAttestationMode(
        release: false,
        debugRequested: false,
        trial: true,
        credentialConfigured: true,
      ),
      AppAttestationMode.device,
    );
    expect(
      appAttestationMode(
        release: true,
        debugRequested: false,
        trial: false,
        credentialConfigured: false,
      ),
      AppAttestationMode.device,
    );
  });
}
