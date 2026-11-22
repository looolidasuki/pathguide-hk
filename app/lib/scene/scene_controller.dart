import 'dart:async';

import 'package:flutter/foundation.dart';

import '../route_memory/route_observation_source.dart';
import '../tts/announcer.dart';
import '../tts/speech_coordinator.dart';
import 'scene_backend.dart';

enum SceneStatus { idle, capturing, analysing, complete, failed, cancelled }

/// A manual, single-frame task. Invalidation fences capture, late replies and
/// speech waiting behind native stop. No background retry or result queue.
class SceneController extends ChangeNotifier {
  SceneController({
    required this.source,
    required this.backend,
    required this.voice,
    this.maxAge = const Duration(seconds: 35),
  }) {
    _events = source.events.listen((status) {
      if ([
        RouteCaptureStatus.paused,
        RouteCaptureStatus.unavailable,
        RouteCaptureStatus.permission,
        RouteCaptureStatus.failed,
        RouteCaptureStatus.stopUnconfirmed,
      ].contains(status)) {
        invalidate();
      }
    }, onError: (Object _) => invalidate());
  }
  final RouteObservationSource source;
  final SceneBackend backend;
  final SpeechCoordinator voice;
  final Duration maxAge;
  StreamSubscription<RouteCaptureStatus>? _events;
  bool _disposed = false, _busy = false, _foreground = true;
  int _generation = 0;
  Timer? _expiry;
  Stopwatch? _elapsed;
  SceneStatus status = SceneStatus.idle;
  String? text, failure;
  SceneMetrics? metrics;
  int? captureMs, uploadModelMs, speechStartMs;
  bool get busy => _busy;
  bool get canDescribe =>
      !_disposed && _foreground && !_busy && source.supported;
  bool get supported => source.supported;
  Speaker get _speaker => voice.channel(SpeechChannel.environment);
  bool _valid(int generation) =>
      !_disposed && _foreground && generation == _generation;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> describe() async {
    if (!canDescribe) return;
    _busy = true;
    final generation = ++_generation;
    status = SceneStatus.capturing;
    text = failure = null;
    metrics = null;
    captureMs = uploadModelMs = speechStartMs = null;
    _elapsed = Stopwatch()..start();
    _expiry?.cancel();
    _expiry = Timer(maxAge, () => invalidate(reason: 'expired'));
    _changed();
    try {
      await _speaker.stop();
      if (!_valid(generation)) return;
      final started = await source.start(
        routeId: 'scene-$generation',
        routeVersion: 1,
      );
      if (!_valid(generation)) return;
      if (started != RouteCaptureStatus.running) {
        throw SceneFailure(started.name);
      }
      var frame = await source.capture();
      // Starting a session does not mean its first camera frame has arrived.
      // Wait only for that first local frame; never retry a cloud request.
      for (
        var attempt = 0;
        frame.status == RouteCaptureStatus.noFrame && attempt < 15;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!_valid(generation)) return;
        frame = await source.capture();
      }
      captureMs = _elapsed!.elapsedMilliseconds;
      if (!_valid(generation)) return;
      if (frame.status != RouteCaptureStatus.captured ||
          frame.keyframe == null) {
        throw SceneFailure(frame.status.name);
      }
      // Release the existing camera lease before cloud work, with exact stop ack.
      final stopped = await source.stop();
      if (!_valid(generation)) return;
      if (stopped != RouteCaptureStatus.stopped) {
        throw const SceneFailure('stopUnconfirmed');
      }
      status = SceneStatus.analysing;
      _changed();
      final network = Stopwatch()..start();
      late final SceneReply reply;
      try {
        reply = await backend.describe(
          frame.keyframe!.bytes,
          sceneRequestId(),
          isCurrent: () => _valid(generation),
        );
      } finally {
        if (!_disposed) uploadModelMs = network.elapsedMilliseconds;
      }
      // Safe usage/timing may survive local cancellation, but never text/speech.
      if (!_disposed) {
        metrics = reply.metrics;
      }
      if (!_valid(generation)) return;
      if (reply.text == null) throw const SceneFailure('rejected');
      text = validateSceneText(reply.text);
      status = SceneStatus.complete;
      _changed();
      try {
        await _speaker.speak(text!);
      } catch (_) {
        if (_valid(generation)) {
          failure = 'speech-unavailable';
          _changed();
        }
      }
    } catch (error) {
      if (!_valid(generation)) return;
      failure = error is SceneFailure ? error.code : 'unavailable';
      text = null;
      status = SceneStatus.failed;
      _changed();
    } finally {
      await source.stop();
      _busy = false;
      if (status != SceneStatus.complete) _expiry?.cancel();
      _changed();
    }
  }

  /// Called by the native TTS start event, not when the HTTP reply arrives.
  /// No event means no measurement (never invent a zero or success).
  void speechStarted() {
    if (_disposed ||
        !_foreground ||
        status != SceneStatus.complete ||
        text == null) {
      return;
    }
    speechStartMs = _elapsed?.elapsedMilliseconds;
    _changed();
  }

  // Future navigation/sensor integration must call this on a significant turn
  // or journey replacement. The standalone entry has NO live turn signal yet.
  void invalidate({String? reason}) {
    if (_disposed) return;
    ++_generation;
    _expiry?.cancel();
    text = null;
    failure = reason;
    status = SceneStatus.cancelled;
    unawaited(_speaker.stop().catchError((Object _) {}));
    unawaited(source.stop());
    _changed();
  }

  void foreground(bool value) {
    _foreground = value;
    if (!value) invalidate();
    _changed();
  }

  @override
  void dispose() {
    invalidate();
    _disposed = true;
    _expiry?.cancel();
    unawaited(_events?.cancel());
    super.dispose();
  }
}
