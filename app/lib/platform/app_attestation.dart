import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

Future<bool>? _activation;

/// App attestation is independent of account sign-in and photo consent.
Future<bool> activateAppAttestation() => _activation ??= _activate();
Future<bool> _activate() async {
  if (kIsWeb || Firebase.apps.isEmpty) return false;
  try {
    const debugRequested = bool.fromEnvironment('APP_CHECK_DEBUG');
    final debug = !kReleaseMode && debugRequested;
    await FirebaseAppCheck.instance.activate(
      providerApple: debug
          ? const AppleDebugProvider()
          : const AppleDeviceCheckProvider(),
      providerAndroid: debug
          ? const AndroidDebugProvider()
          : const AndroidPlayIntegrityProvider(),
    );
    return true;
  } catch (_) {
    return false;
  }
}
