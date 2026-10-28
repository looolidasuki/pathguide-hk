import 'dart:async';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../account/account_controller.dart';
import 'photo_models.dart';

class PhotoController extends ChangeNotifier {
  PhotoController({
    required this.account,
    required this.backend,
    required this.queue,
    required this.network,
    required this.project,
  }) {
    account.addListener(_accountChanged);
    _accountChanged();
  }
  final AccountController account;
  final PhotoBackend backend;
  final PhotoQueue queue;
  final PhotoNetwork network;
  final String project;
  String? _uid;
  int _generation = 0;
  bool enabled = false, autoCapture = false, busy = false;
  int epoch = 0, count = 0;
  String? message;
  List<Map<String, dynamic>> cloudProgress = [];
  bool _disposed = false, _uploading = false, _capturing = false;
  bool _foreground = true;
  bool _localPaused = false;
  Future<void> _transition = Future.value();
  final _random = Random.secure();
  final Set<String> _seen = {};
  final List<BigInt> _fingerprints = [];
  DateTime? _lastAutomatic;
  DateTime? _lastScene;
  String _day = '';
  int _dailyAuto = 0, _dailyScene = 0;
  String _id() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  bool get available =>
      backend.configured &&
      _uid != null &&
      account.profileReady &&
      !account.deletionPending;
  bool get canCapture => available && enabled && !busy && _foreground;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _current(int generation, String uid) =>
      !_disposed &&
      generation == _generation &&
      account.identity?.uid == uid &&
      account.auth.current?.uid == uid &&
      !account.deletionPending;
  void _accountChanged() {
    final next = account.deletionPending ? null : account.identity?.uid;
    if (next == _uid) {
      _notify();
      return;
    }
    final previous = _uid;
    _uid = next;
    final generation = ++_generation;
    enabled = autoCapture = false;
    busy = false;
    count = 0;
    cloudProgress = [];
    _seen.clear();
    _fingerprints.clear();
    message = null;
    // Serialize account transitions so a late cleanup cannot erase a new account's queue.
    _transition = _transition.catchError((Object _) {}).then((_) async {
      try {
        final existing = await queue.read();
        if (previous != null ||
            next == null ||
            existing.any((p) => p.uid != next || p.project != project)) {
          await queue.clear();
        }
        if (next != null && _current(generation, next) && backend.configured) {
          await refresh();
        }
      } catch (_) {
        if (_current(generation, next ?? '')) {
          message = '未能讀取私人待傳資料，照片收集保持關閉。';
        }
      } finally {
        _notify();
      }
    });
    _notify();
  }

  Future<void> refresh() async {
    final uid = _uid;
    if (uid == null || !backend.configured) return;
    final generation = _generation;
    try {
      final consent = await backend.readConsent(uid);
      if (!_current(generation, uid)) return;
      _localPaused = await queue.uploadsPaused();
      if (!_current(generation, uid)) return;
      enabled = consent.enabled && !_localPaused;
      epoch = consent.epoch;
      final entries = await queue.read();
      if (!_current(generation, uid)) return;
      for (final p in entries) {
        if (p.uid != uid || p.project != project || p.epoch != epoch) {
          await queue.remove(p.id);
        }
      }
      count = (await queue.read()).length;
      final progress = await backend.progress(uid);
      if (!_current(generation, uid)) return;
      cloudProgress = progress;
      message = enabled ? '收集已開啟，自動擷取另行選擇；待傳照片只經 Wi-Fi 上傳。' : '照片收集已關閉。';
    } catch (_) {
      if (_current(generation, uid)) {
        enabled = false;
        message = '未能確認雲端同意狀態，收集及上傳保持關閉；可連網後重試。';
      }
    }
    _notify();
  }

  Future<void> setEnabled(bool value) async {
    final uid = _uid;
    if (!available || uid == null || busy) return;
    final generation = _generation;
    // Revocation stops local work immediately even when the server cannot be reached.
    enabled = false;
    autoCapture = false;
    busy = true;
    _notify();
    try {
      _localPaused = true;
      await queue.pauseUploads(true);
      if (!value) {
        await queue.clear();
        count = 0;
      }
      final consent = await backend.setConsent(uid, value);
      if (!_current(generation, uid)) return;
      await queue.pauseUploads(false);
      if (!_current(generation, uid)) return;
      _localPaused = false;
      epoch = consent.epoch;
      enabled = consent.enabled;
      if (!value) {
        await queue.clear();
        count = 0;
      }
      message = value
          ? '已同意照片用途。自動擷取預設關閉，可先手動回報。'
          : '已關閉收集並清除本機待傳；雲端既有照片仍依保留規則處理。';
    } catch (_) {
      if (_current(generation, uid)) message = '雲端設定未更新。本機收集及上傳已停止，請連網後重試。';
    } finally {
      if (_current(generation, uid)) {
        busy = false;
        _notify();
      }
    }
  }

  void setAutomatic(bool value) {
    autoCapture = value && canCapture;
    _notify();
  }

  void foreground(bool value) {
    _foreground = value;
    if (!value) autoCapture = false;
    _notify();
  }

  Future<void> capture(
    Future<CapturedPhoto?> Function(String trigger) source, {
    String trigger = 'manual_report',
  }) async {
    final uid = _uid;
    if (!canCapture || uid == null || _capturing) return;
    final automatic = trigger != 'manual_report';
    final now = DateTime.now().toUtc();
    if (_day != now.toIso8601String().substring(0, 10)) {
      _day = now.toIso8601String().substring(0, 10);
      _dailyAuto = _dailyScene = 0;
    }
    if (automatic &&
        (!autoCapture ||
            _dailyAuto >= 50 ||
            (_lastAutomatic != null &&
                now.difference(_lastAutomatic!) <
                    const Duration(seconds: 30)) ||
            (trigger == 'scene_sample' &&
                (_dailyScene >= 10 ||
                    (_lastScene != null &&
                        now.difference(_lastScene!) <
                            const Duration(minutes: 1)))))) {
      return;
    }
    final generation = _generation, consentEpoch = epoch;
    _capturing = true;
    try {
      final existing = await queue.read();
      if (existing.length >= maxQueueCount ||
          existing.fold<int>(0, (n, p) => n + p.jpeg.length) >= maxQueueBytes) {
        throw const PhotoFailure('待傳已滿，請先上傳或清除待傳照片。');
      }
      if (!_current(generation, uid) || !canCapture) return;
      final captured = await source(trigger);
      if (!_current(generation, uid) ||
          !canCapture ||
          epoch != consentEpoch ||
          captured == null) {
        return;
      }
      final jpeg = captured.jpeg;
      if (jpeg.isEmpty || jpeg.length > maxPhotoBytes) {
        throw const PhotoFailure('照片大小不符合限制，請重試。');
      }
      if (existing.fold<int>(0, (n, p) => n + p.jpeg.length) + jpeg.length >
          maxQueueBytes) {
        throw const PhotoFailure('待傳容量不足。');
      }
      final fingerprint = BigInt.tryParse(
        captured.metadata['perceptualHash'] as String? ?? '',
        radix: 16,
      );
      if (automatic &&
          fingerprint != null &&
          _fingerprints.any(
            (old) =>
                (old ^ fingerprint)
                    .toRadixString(2)
                    .split('')
                    .where((v) => v == '1')
                    .length <
                6,
          )) {
        message = '場景與近期候選相似，略過自動擷取。';
        return;
      }
      final hash = sha256.convert(jpeg).toString();
      if (_seen.contains(hash) ||
          existing.any((p) => p.metadata['sha256'] == hash)) {
        message = '相同照片已在待傳清單。';
        return;
      }
      final p = QueuedPhoto(
        id: _id(),
        uid: uid,
        project: project,
        epoch: epoch,
        createdAt: now,
        jpeg: Uint8List.fromList(jpeg),
        metadata: {
          ...captured.metadata,
          'trigger': trigger,
          'sha256': hash,
          'sessionId': sessionId,
          'capturedAtClient':
              captured.metadata['capturedAtClient'] ?? now.toIso8601String(),
        },
      );
      await queue.put(p);
      if (!_current(generation, uid) || !canCapture || epoch != consentEpoch) {
        await queue.remove(p.id);
        return;
      }
      _seen.add(hash);
      if (fingerprint != null) {
        _fingerprints.add(fingerprint);
        if (_fingerprints.length > 50) _fingerprints.removeAt(0);
      }
      count++;
      if (automatic) {
        _dailyAuto++;
        _lastAutomatic = now;
        if (trigger == 'scene_sample') {
          _dailyScene++;
          _lastScene = now;
        }
      }
      message = '照片已加入私人待傳清單，尚未上傳或加入訓練。';
    } catch (error) {
      if (_current(generation, uid)) {
        message = error is PhotoFailure ? error.message : '未能擷取或保存照片，辨識可繼續使用。';
      }
    } finally {
      _capturing = false;
      _notify();
    }
  }

  late final String sessionId = _id();
  Future<void> uploadPending() async {
    final uid = _uid;
    if (!canCapture || uid == null || _uploading) return;
    final generation = _generation, consentEpoch = epoch;
    _uploading = true;
    _notify();
    try {
      if (!await network.wifiAvailable()) {
        throw const PhotoFailure('待傳照片會保留，請連接 Wi-Fi 後重試。');
      }
      for (final photo in await queue.read()) {
        if (!_current(generation, uid) ||
            !canCapture ||
            epoch != consentEpoch) {
          break;
        }
        if (photo.uid != uid ||
            photo.project != project ||
            photo.epoch != epoch) {
          await queue.remove(photo.id);
          continue;
        }
        if (!await network.wifiAvailable()) break;
        await backend.upload(photo);
        await queue.remove(photo.id);
        if (_current(generation, uid)) {
          count = (await queue.read()).length;
          message = '照片已上傳，等待人工覆核；尚未訓練。';
        }
      }
    } catch (error) {
      if (_current(generation, uid)) {
        message = error is PhotoFailure ? error.message : '上傳未完成，照片保留待傳；可稍後重試。';
      }
    } finally {
      _uploading = false;
      _notify();
    }
  }

  Future<void> clearPending() async {
    if (_capturing || _uploading) return;
    await queue.clear();
    count = 0;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
