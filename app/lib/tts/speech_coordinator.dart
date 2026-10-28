import 'dart:async';

import 'announcer.dart';

enum SpeechChannel { environment, navigation }

/// One output, with navigation taking priority. Camera speech is never queued.
/// Generations also invalidate requests waiting for a slow native stop call.
class SpeechCoordinator {
  SpeechCoordinator(this.output);
  final Speaker output;
  Future<void> _operations = Future<void>.value();
  SpeechChannel? _owner;
  int _generation = 0;
  bool _suspended = false;

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

  Future<void> stop([SpeechChannel? channel]) {
    if (channel != null && _owner != null && channel.index < _owner!.index) {
      return Future<void>.value();
    }
    ++_generation;
    _owner = null;
    return _serialize(output.stop);
  }

  Future<void> _speak(SpeechChannel channel, String text) async {
    if (_suspended ||
        (_owner != null &&
            channel.index <= _owner!.index &&
            channel == SpeechChannel.environment)) {
      return;
    }
    final generation = ++_generation;
    _owner = channel;
    Future<void>? utterance;
    try {
      await _serialize(() async {
        if (_suspended || generation != _generation) return;
        await output.stop();
        if (_suspended || generation != _generation) return;
        // Release the command lock while speech plays, allowing preemption.
        utterance = output.speak(text);
        unawaited(utterance!.catchError((Object _) {}));
      });
      await utterance;
    } finally {
      if (generation == _generation) _owner = null;
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
