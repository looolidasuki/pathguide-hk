import 'package:pathguide/menu/menu_document.dart';
import 'package:pathguide/menu/menu_reader.dart';
import 'package:pathguide/tts/announcer.dart';

class FakeMenuReader implements MenuReader {
  @override
  bool supported = true;
  int reads = 0, listens = 0, cancels = 0, finishes = 0;
  String? phrase = '我想食牛腩飯';
  MenuDocument? document;
  MenuFailure? speechError;
  MenuFailure? readError;
  bool notifyRecognizing = true;
  Future<MenuDocument?>? readFuture;
  Future<String?>? speechFuture;
  @override
  Future<MenuDocument?> read(
    MenuImageSource source, {
    required void Function() onRecognizing,
  }) async {
    reads++;
    if (readError != null) throw readError!;
    if (notifyRecognizing) onRecognizing();
    return readFuture ?? Future.value(document);
  }

  @override
  Future<MenuSpeechResult> listen({
    required bool allowNetwork,
    required void Function(String) onPartial,
    required void Function(MenuSpeechPhase) onPhase,
  }) async {
    listens++;
    if (speechError != null && !allowNetwork) throw speechError!;
    onPhase(MenuSpeechPhase.listening);
    onPartial(phrase ?? '');
    final text = await (speechFuture ?? Future.value(phrase));
    onPhase(MenuSpeechPhase.finishing);
    return MenuSpeechResult(
      text == null || text.isEmpty
          ? MenuSpeechOutcome.noSpeech
          : MenuSpeechOutcome.finalText,
      text: text ?? '',
    );
  }

  @override
  Future<void> finishListening() async {
    finishes++;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  void dispose() {}
}

class MenuTestSpeaker implements Speaker {
  final utterances = <String>[];
  @override
  Future<void> speak(String text) async {
    utterances.add(text);
  }

  @override
  Future<void> stop() async {}
  @override
  Future<List<String>> languages() async => ['zh-HK'];
}

MenuDocument sampleMenu() => parseMenu([
  const MenuLine(
    text: '午餐',
    page: 1,
    left: .1,
    top: .1,
    width: .3,
    height: .03,
    confidence: .95,
  ),
  const MenuLine(
    text: '牛腩飯 \$48',
    page: 1,
    left: .1,
    top: .2,
    width: .5,
    height: .03,
    confidence: .95,
  ),
  const MenuLine(
    text: '叉燒飯 \$45',
    page: 1,
    left: .1,
    top: .3,
    width: .5,
    height: .03,
    confidence: .95,
  ),
], pages: 1);
