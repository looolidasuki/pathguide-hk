import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

Future<bool>? _activation;

enum AppAttestationMode { device, debug, unavailable }

/// Release builds never accept the test provider. Private engineering trials
/// must supply a separately registered credential instead of logging one.
AppAttestationMode appAttestationMode({
  required bool release,
  required bool debugRequested,
  required bool trial,
  required bool credentialConfigured,
}) {
  if (release || !debugRequested) return AppAttestationMode.device;
  if (trial && !credentialConfigured) return AppAttestationMode.unavailable;
  return AppAttestationMode.debug;
}

/// App attestation is independent of account sign-in and photo consent.
Future<bool> activateAppAttestation() => _activation ??= _activate();
Future<bool> _activate() async {
  if (kIsWeb || Firebase.apps.isEmpty) return false;
  try {
    const debugRequested = bool.fromEnvironment('APP_CHECK_DEBUG');
    const debugToken = String.fromEnvironment('APP_CHECK_DEBUG_TOKEN');
    final mode = appAttestationMode(
      release: kReleaseMode,
      debugRequested: debugRequested,
      trial: const bool.fromEnvironment('SCENE_DESCRIPTION_TRIAL'),
      credentialConfigured: debugToken.isNotEmpty,
    );
    if (mode == AppAttestationMode.unavailable) return false;
    final debug = mode == AppAttestationMode.debug;
    await FirebaseAppCheck.instance.activate(
      providerApple: debug
          ? AppleDebugProvider(
              debugToken: debugToken.isEmpty ? null : debugToken,
            )
          : const AppleDeviceCheckProvider(),
      providerAndroid: debug
          ? AndroidDebugProvider(
              debugToken: debugToken.isEmpty ? null : debugToken,
            )
          : const AndroidPlayIntegrityProvider(),
    );
    // Activation alone does not prove this device can get a valid token.
    // Fail before an image upload rather than sending an SDK placeholder token.
    final token = await FirebaseAppCheck.instance
        .getToken(true)
        .timeout(const Duration(seconds: 12));
    return token != null && token.isNotEmpty;
  } catch (_) {
    return false;
  }
}
