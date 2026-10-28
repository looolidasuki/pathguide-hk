import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/tts/announcer.dart';
import 'package:pathguide/tts/speech_coordinator.dart';

class Output implements Speaker {
  final words = <String>[];
  Completer<void>? speaking;
  Completer<void>? stopping;
  @override
  Future<void> speak(String text) {
    words.add(text);
    speaking = Completer<void>();
    return speaking!.future;
  }

  @override
  Future<void> stop() async {
    await stopping?.future;
    finish();
  }

  void finish() {
    if (speaking != null && !speaking!.isCompleted) speaking!.complete();
  }

  @override
  Future<List<String>> languages() async => ['en-GB'];
}

Future<void> tick() => Future<void>.delayed(Duration.zero);
void main() {
  test(
    'navigation preempts recognition, which cannot stop or queue behind it',
    () async {
      final out = Output();
      final voice = SpeechCoordinator(out);
      final env = voice.channel(SpeechChannel.environment);
      final nav = voice.channel(SpeechChannel.navigation);
      final first = env.speak('bin');
      await tick();
      final route = nav.speak('turn left');
      await tick();
      await first;
      await env.stop();
      await env.speak('stale stairs');
      expect(out.words, ['bin', 'turn left']);
      out.finish();
      await route;
      await tick();
      expect(out.words, ['bin', 'turn left']);
      final fresh = env.speak('door');
      await tick();
      expect(out.words.last, 'door');
      out.finish();
      await fresh;
    },
  );
  test('suspending during native stop invalidates pending speech', () async {
    final out = Output()..stopping = Completer<void>();
    final voice = SpeechCoordinator(out);
    final pending = voice.channel(SpeechChannel.environment).speak('old frame');
    await tick();
    final pause = voice.suspend(true);
    out.stopping!.complete();
    await pending;
    await pause;
    await voice.channel(SpeechChannel.navigation).speak('hidden');
    expect(out.words, isEmpty);
    await voice.suspend(false);
    final fresh = voice.channel(SpeechChannel.navigation).speak('resume');
    await tick();
    expect(out.words, ['resume']);
    out.finish();
    await fresh;
  });
}
