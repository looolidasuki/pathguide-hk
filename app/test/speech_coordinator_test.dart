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
  test('clearing scene status withdraws only that notice and cannot stop navigation', () async {
    final out = Output();
    final voice = SpeechCoordinator(out);
    final notice = voice.speakStatus('等候更新', isCurrent: () => true);
    await tick();
    expect(out.words, ['等候更新']);
    await voice.stopOwned(SpeechChannel.sceneStatus);
    await notice;
    final route = voice.channel(SpeechChannel.navigation).speak('導航');
    await tick();
    await voice.stopOwned(SpeechChannel.sceneStatus);
    expect(out.speaking!.isCompleted, isFalse);
    out.finish();
    await route;
  });
  test('status notice revalidates after native stop and never announces an obsolete state', () async {
    final out = Output()..stopping = Completer<void>();
    final voice = SpeechCoordinator(out);
    var current = true;
    final work = voice.speakStatus('等候更新', isCurrent: () => current);
    await tick();
    current = false;
    out.stopping!.complete();
    await work;
    expect(out.words, isEmpty);
  });
  test(
    'fresh scene waits for a local alert and submits once after it finishes',
    () async {
      final out = Output();
      final voice = SpeechCoordinator(out);
      final events = <SceneSpeechEvent>[];
      final alert = voice.channel(SpeechChannel.environment).speak('物件提示');
      await tick();
      final scene = voice.speakScene(
        '場景描述',
        isCurrent: () => true,
        onEvent: events.add,
      );
      await tick();
      expect(out.words, ['物件提示']);
      expect(events, [SceneSpeechEvent.waiting]);
      out.finish();
      await alert;
      await tick();
      expect(out.words, ['物件提示', '場景描述']);
      out.finish();
      await scene;
      expect(events, [
        SceneSpeechEvent.waiting,
        SceneSpeechEvent.submitted,
        SceneSpeechEvent.finished,
      ]);
    },
  );
  test(
    'scene cancellation withdraws its wait without stopping the local alert',
    () async {
      final out = Output();
      final voice = SpeechCoordinator(out);
      final events = <SceneSpeechEvent>[];
      final alert = voice.channel(SpeechChannel.environment).speak('物件提示');
      await tick();
      final scene = voice.speakScene(
        '舊場景',
        isCurrent: () => true,
        onEvent: events.add,
      );
      await tick();
      await voice.channel(SpeechChannel.scene).stop();
      await scene;
      expect(events.last, SceneSpeechEvent.cancelled);
      expect(out.speaking!.isCompleted, isFalse);
      out.finish();
      await alert;
      expect(out.words, ['物件提示']);
    },
  );
  test('waiting scene expires explicitly and navigation never releases stale queued speech', () async {
    final out = Output();
    final voice = SpeechCoordinator(out);
    final events = <SceneSpeechEvent>[];
    final alert = voice.channel(SpeechChannel.environment).speak('物件提示');
    await tick();
    await voice.speakScene(
      '過期場景',
      isCurrent: () => true,
      onEvent: events.add,
      waitLimit: const Duration(milliseconds: 5),
    );
    expect(events.last, SceneSpeechEvent.priorityTimeout);
    final scene = voice.speakScene(
      '舊場景',
      isCurrent: () => true,
      onEvent: events.add,
    );
    await tick();
    final route = voice.channel(SpeechChannel.navigation).speak('導航');
    await scene;
    await tick();
    await alert;
    expect(events.last, SceneSpeechEvent.navigationBlocked);
    out.finish();
    await route;
    expect(out.words, ['物件提示', '導航']);
  });
  test(
    'scene waiting behind a slow native stop revalidates before any output',
    () async {
      final out = Output()..stopping = Completer<void>();
      final voice = SpeechCoordinator(out);
      var current = true;
      final events = <SceneSpeechEvent>[];
      final scene = voice.speakScene(
        '舊場景',
        isCurrent: () => current,
        onEvent: events.add,
      );
      await tick();
      current = false;
      out.stopping!.complete();
      await scene;
      expect(out.words, isEmpty);
      expect(events, [SceneSpeechEvent.cancelled]);
    },
  );
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
