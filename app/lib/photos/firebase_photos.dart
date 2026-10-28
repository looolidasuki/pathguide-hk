import 'dart:async';
import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../platform/app_attestation.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../account/account_controller.dart';
import 'encrypted_photo_queue.dart';
import 'photo_controller.dart';
import 'photo_models.dart';

class FirebasePhotoBackend implements PhotoBackend {
  FirebasePhotoBackend({required this.configured, this._functions});
  @override
  final bool configured;
  final FirebaseFunctions? _functions;
  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> data,
  ) async {
    if (!configured) throw const PhotoFailure('照片雲端服務尚未配置，收集保持關閉。');
    final result = await _functions!
        .httpsCallable(
          name,
          options: HttpsCallableOptions(timeout: const Duration(seconds: 40)),
        )
        .call<dynamic>(data);
    return Map<String, dynamic>.from(result.data as Map);
  }

  PhotoConsent _consent(Map<String, dynamic> v) =>
      PhotoConsent(enabled: v['enabled'] == true, epoch: v['epoch'] as int);
  @override
  Future<PhotoConsent> readConsent(String uid) async =>
      _consent(await _call('getPhotoConsent', {'expectedUid': uid}));
  @override
  Future<PhotoConsent> setConsent(String uid, bool enabled) async => _consent(
    await _call('setPhotoConsent', {
      'expectedUid': uid,
      'enabled': enabled,
      'noticeVersion': photoNoticeVersion,
    }),
  );
  @override
  Future<List<Map<String, dynamic>>> progress(String uid) async {
    final v = await _call('listPhotoProgress', {'expectedUid': uid});
    return (v['photos'] as List)
        .map((p) => Map<String, dynamic>.from(p as Map))
        .toList();
  }

  @override
  Future<void> upload(QueuedPhoto p) async {
    final result = await _call('submitPhoto', {
      'expectedUid': p.uid,
      'photoId': p.id,
      'consentEpoch': p.epoch,
      'metadata': p.metadata,
      'jpegBase64': base64Encode(p.jpeg),
    });
    if (result['uploadStatus'] != 'validated') {
      throw const PhotoFailure('雲端未確認照片有效，已保留待傳。');
    }
  }
}

class WifiPhotoNetwork implements PhotoNetwork {
  @override
  Future<bool> wifiAvailable() async =>
      (await Connectivity().checkConnectivity()).contains(
        ConnectivityResult.wifi,
      );
}

Future<PhotoController> configuredPhotos(AccountController account) async {
  const requested = bool.fromEnvironment('PHOTO_UPLOAD_ENABLED');
  const project = String.fromEnvironment('FIREBASE_PROJECT_ID');
  bool ready = false;
  if (requested &&
      account.configured &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS) {
    try {
      ready = await activateAppAttestation();
    } catch (_) {
      ready = false;
    }
  }
  return PhotoController(
    account: account,
    backend: FirebasePhotoBackend(
      configured: ready,
      functions: ready
          ? FirebaseFunctions.instanceFor(region: 'asia-east2')
          : null,
    ),
    queue: EncryptedPhotoQueue(project: project),
    network: WifiPhotoNetwork(),
    project: project,
  );
}

/// The JPEG and predictions are returned by one native inference, never a UI screenshot.
Future<CapturedPhoto?> captureNativePhoto(
  String trigger, {
  required String modelVersion,
  required String classMapVersion,
}) async {
  final result = await const MethodChannel('hk.pathguide/vision')
      .invokeMapMethod<String, dynamic>('captureFrame', {'trigger': trigger})
      .timeout(const Duration(seconds: 6));
  if (result == null || result['jpeg'] == null) return null;
  return CapturedPhoto(
    jpeg: result['jpeg'] as Uint8List,
    metadata: {
      'perceptualHash': result['perceptualHash'],
      'capturedAtClient': result['capturedAtClient'],
      'width': result['width'],
      'height': result['height'],
      'predictions': result['predictions'],
      'modelVersion': modelVersion,
      'classMapVersion': classMapVersion,
    },
  );
}
