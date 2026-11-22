import 'dart:async';

import 'announcer.dart';

enum SpeechChannel { scene, environment, sceneStatus, navigation }

enum SceneSpeechEvent {
  waiting,
  submitted,
  finished,
  cancelled,
  interrupted,
  priorityTimeout,
  navigationBlocked,
  failed,
}

/// One output, with navigation taking priority. Detector speech never queues;
/// one current scene may wait briefly for an alert to finish. Generations also
/// invalidate requests waiting for a slow native stop call.
class SpeechCoordinator {
  SpeechCoordinator(this.output);
  final Speaker output;
  Future<void> _operations = Future<void>.value();
  SpeechChannel? _owner;
  int _generation = 0;
  bool _suspended = false;
  int _sceneRequest = 0;
  Completer<void> _ownerChanged = Completer<void>();
  SpeechChannel? get owner => _owner;
  void _changed() {
    final previous = _ownerChanged;
    _ownerChanged = Completer<void>();
    if (!previous.isCompleted) previous.complete();
  }

  /// One fresh scene may wait briefly for a local alert to finish. It never
  /// interrupts an alert, waits behind navigation, or retries cloud work.
  Future<void> speakScene(
    String text, {
    required bool Function() isCurrent,
    required void Function(SceneSpeechEvent) onEvent,
    Duration waitLimit = const Duration(seconds: 3),
  }) async {
    final request = ++_sceneRequest;
    final elapsed = Stopwatch()..start();
    bool valid() => request == _sceneRequest && !_suspended && isCurrent();
    var waiting = false;
    for (;;) {
      if (!valid()) {
        onEvent(SceneSpeechEvent.cancelled);
        return;
      }
      if (_owner == SpeechChannel.navigation) {
        onEvent(SceneSpeechEvent.navigationBlocked);
        return;
      }
      if (_owner == null) break;
      if (!waiting) {
        waiting = true;
        onEvent(SceneSpeechEvent.waiting);
      }
      final remaining = waitLimit - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        onEvent(SceneSpeechEvent.priorityTimeout);
        return;
      }
      try {
        await _ownerChanged.future.timeout(remaining);
      } on TimeoutException {
        onEvent(SceneSpeechEvent.priorityTimeout);
        return;
      }
    }
    await _speak(
      SpeechChannel.scene,
      text,
      isCurrent: valid,
      onSceneEvent: onEvent,
    );
  }

  Future<void> speakStatus(String text, {required bool Function() isCurrent}) =>
      _speak(SpeechChannel.sceneStatus, text, isCurrent: isCurrent);

  Speaker channel(SpeechChannel channel) => _ChannelSpeaker(this, channel);

  Future<void> _serialize(Future<void> Function() action) {
    final next = _operations.then((_) => action());
    _operations = next.catchError((Object _) {});
    return next;
  }

  Future<void> suspend(bool value) async {
    _suspended = value;
    if (value) await stop();
  }

  /// Withdraw stale results from only their current producer. A detector
  /// timeout must not cancel a fresh scene or navigation utterance.
  Future<void> stopOwned(SpeechChannel channel) =>
      _owner == channel ? stop(channel) : Future<void>.value();

  Future<void> stop([SpeechChannel? channel]) {
    if (channel == null ||
        channel == SpeechChannel.scene ||
        channel == SpeechChannel.navigation) {
      ++_sceneRequest;
      _changed();
    }
    if (channel != null && _owner != null && channel.index < _owner!.index) {
      return Future<void>.value();
    }
    ++_generation;
    _owner = null;
    _changed();
    return _serialize(output.stop);
  }

  Future<void> _speak(
    SpeechChannel channel,
    String text, {
    bool Function()? isCurrent,
    void Function(SceneSpeechEvent)? onSceneEvent,
  }) async {
    if (_suspended ||
        (_owner != null &&
            channel.index <= _owner!.index &&
            channel != SpeechChannel.navigation)) {
      onSceneEvent?.call(SceneSpeechEvent.cancelled);
      return;
    }
    final generation = ++_generation;
    _owner = channel;
    _changed();
    Future<void>? utterance;
    try {
      await _serialize(() async {
        if (_suspended ||
            generation != _generation ||
            !(isCurrent?.call() ?? true)) {
          return;
        }
        await output.stop();
        if (_suspended ||
            generation != _generation ||
            !(isCurrent?.call() ?? true)) {
          return;
        }
        // Release the command lock while speech plays, allowing preemption.
        onSceneEvent?.call(SceneSpeechEvent.submitted);
        utterance = output.speak(text);
        unawaited(utterance!.catchError((Object _) {}));
      });
      await utterance;
      onSceneEvent?.call(
        utterance == null
            ? SceneSpeechEvent.cancelled
            : generation == _generation
            ? SceneSpeechEvent.finished
            : SceneSpeechEvent.interrupted,
      );
    } catch (_) {
      onSceneEvent?.call(SceneSpeechEvent.failed);
      rethrow;
    } finally {
      if (generation == _generation) {
        _owner = null;
        _changed();
      }
    }
  }
}

class _ChannelSpeaker implements Speaker {
  _ChannelSpeaker(this.coordinator, this.source);
  final SpeechCoordinator coordinator;
  final SpeechChannel source;
  @override
  Future<void> speak(String text) => coordinator._speak(source, text);
  @override
  Future<void> stop() => coordinator.stop(source);
  @override
  Future<List<String>> languages() => coordinator.output.languages();
}
