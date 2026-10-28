import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/tts/announcer.dart';
import 'package:pathguide/tts/environment_speaker.dart';

class RecordingSpeaker extends NullSpeaker {
  final spoken = <String>[];
  @override
  Future<void> speak(String text) async => spoken.add(text);
}

void main() {
  test(
    'each result uses exactly one output route as the reader changes',
    () async {
      final tts = RecordingSpeaker();
      final announcements = <String>[];
      var reader = false;
      final speaker = EnvironmentSpeaker(
        tts: tts,
        screenReaderActive: () => reader,
        announce: (text) async => announcements.add(text),
      );
      await speaker.speak('垃圾桶');
      reader = true;
      await speaker.speak('單車');
      expect(tts.spoken, ['垃圾桶']);
      expect(announcements, ['單車']);
    },
  );
}
