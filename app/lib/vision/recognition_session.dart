import 'dart:async';

import 'package:flutter/foundation.dart';

import '../tts/announcer.dart';
import 'vision_source.dart';

/// Camera ownership for navigation. No photo storage/upload is performed.
/// Stop invalidates callbacks immediately; native start/stop remain serialized.
class RecognitionSession extends ChangeNotifier {
  RecognitionSession({required this.createSource, required this.announcer});
  final VisionSource Function() createSource;
  final Announcer announcer;
  VisionSource? source;
  VisionFrame? frame;
  String status = '辨識已停止';
  bool requested = false, ready = false, _disposed = false;
  int _generation = 0;
  StreamSubscription<VisionFrame>? _subscription;
  Future<void> _transition = Future<void>.value();
  Timer? _freshness;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _streamFailed(int generation) {
    if (_disposed || generation != _generation) return;
    _freshness?.cancel();
    ready = false;
    announcer.enabled = false;
    frame = null;
    status = '辨識暫時不可用，請停止後重試。';
    _notify();
  }

  Future<void> setRunning(bool value) {
    if (_disposed || value == requested) return _transition;
    requested = value;
    final generation = ++_generation;
    announcer.enabled = false;
    _freshness?.cancel();
    frame = null;
    ready = false;
    status = value ? '正在準備辨識…' : '辨識已停止';
    _notify();
    _transition = _transition
        .then((_) async {
          await _subscription?.cancel();
          _subscription = null;
          final old = source;
          source = null;
          await old?.dispose();
          if (_disposed || generation != _generation || !requested) return;
          final next = createSource();
          source = next;
          _subscription = next.frames.listen(
            (value) {
              if (_disposed || generation != _generation || !ready) return;
              frame = value;
              status = '辨識中';
              _freshness?.cancel();
              _freshness = Timer(const Duration(seconds: 3), () {
                if (_disposed || generation != _generation) return;
                frame = null;
                status = '暫時未有最新結果，請保持手機穩定再試。';
                _notify();
              });
              announcer.onFrame(value.detections);
              _notify();
            },
            onError: (Object error) => _streamFailed(generation),
            onDone: () => _streamFailed(generation),
          );
          try {
            final result = await next.initialize();
            if (_disposed || generation != _generation) return;
            ready = result.ok;
            status = result.message;
            announcer.reset();
            announcer.enabled = ready;
          } catch (_) {
            if (_disposed || generation != _generation) return;
            status = '辨識暫時不可用，請停止後重試。';
          }
          _notify();
        })
        .catchError((Object _) {
          if (_disposed || generation != _generation) return;
          ready = false;
          status = '辨識暫時不可用，請停止後重試。';
          _notify();
        });
    return _transition;
  }

  @override
  void dispose() {
    unawaited(setRunning(false));
    _disposed = true;
    ++_generation;
    announcer.enabled = false;
    super.dispose();
  }
}
