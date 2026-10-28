import 'dart:typed_data';

const photoNoticeVersion = '2026-10-23.personal-photos.v1';
const maxPhotoBytes = 2 * 1024 * 1024;
const maxQueueBytes = 50 * 1024 * 1024;
const maxQueueCount = 50;

class PhotoFailure implements Exception {
  const PhotoFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class PhotoConsent {
  const PhotoConsent({required this.enabled, required this.epoch});
  final bool enabled;
  final int epoch;
}

class CapturedPhoto {
  const CapturedPhoto({required this.jpeg, required this.metadata});
  final Uint8List jpeg;
  // The native capture returns pixels and predictions from the same inference.
  final Map<String, dynamic> metadata;
}

class QueuedPhoto {
  const QueuedPhoto({
    required this.id,
    required this.uid,
    required this.project,
    required this.epoch,
    required this.createdAt,
    required this.jpeg,
    required this.metadata,
  });
  final String id, uid, project;
  final int epoch;
  final DateTime createdAt;
  final Uint8List jpeg;
  final Map<String, dynamic> metadata;
}

abstract class PhotoBackend {
  bool get configured;
  Future<PhotoConsent> readConsent(String uid);
  Future<PhotoConsent> setConsent(String uid, bool enabled);
  Future<void> upload(QueuedPhoto photo);
  Future<List<Map<String, dynamic>>> progress(String uid);
}

abstract class PhotoQueue {
  Future<List<QueuedPhoto>> read();
  Future<void> put(QueuedPhoto photo);
  Future<void> remove(String id);
  Future<void> clear();
  Future<bool> uploadsPaused();
  Future<void> pauseUploads(bool paused);
}

abstract class PhotoNetwork {
  Future<bool> wifiAvailable();
}
