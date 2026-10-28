import 'package:flutter/foundation.dart';

import 'menu_document.dart';
import 'menu_reader.dart';

enum MenuState {
  ready,
  acquiring,
  recognizing,
  preparing,
  listening,
  finishing,
  result,
  failed,
}

class MenuReadingController extends ChangeNotifier {
  MenuReadingController(this.reader);
  final MenuReader reader;
  MenuState state = MenuState.ready;
  MenuDocument? document;
  String query = '', partial = '', message = '先拍攝或選取一張菜單。';
  String? section;
  String? voiceReadout;
  String rawTranscript = '';
  int _generation = 0;
  bool _disposed = false;
  bool get busy => [
    MenuState.acquiring,
    MenuState.recognizing,
    MenuState.preparing,
    MenuState.listening,
    MenuState.finishing,
  ].contains(state);
  bool get canSearch => document != null && !busy;
  List<MenuEntry> get results =>
      document?.search(query, section: section) ?? [];
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> read(MenuImageSource source) async {
    if (busy) return;
    final generation = ++_generation;
    document = null;
    query = '';
    section = null;
    state = MenuState.acquiring;
    message = source == MenuImageSource.library ? '正在開啟照片選取。' : '正在開啟菜單拍攝。';
    _notify();
    try {
      final d = await reader.read(
        source,
        onRecognizing: () {
          if (!_disposed && generation == _generation) {
            state = MenuState.recognizing;
            message = '正在手機上辨識菜單文字。';
            _notify();
          }
        },
      );
      if (_disposed || generation != _generation) return;
      document = d;
      state = d == null ? MenuState.ready : MenuState.result;
      message = d == null
          ? '已取消，請重新拍攝或選取菜單。'
          : d.entries.isEmpty
          ? '暫未讀到可用文字，請調整光線或重拍。'
          : '辨識到 ${d.sections.length} 個分類、${d.entries.length} 段內容。請先選分類，或講出想食的菜式。${d.truncated ? "只處理首三頁或部分文字，請分開重拍。" : ""}';
      if (d != null && d.warnings.isNotEmpty) {
        message += ' ${d.warnings.join(' ')}';
      }
    } catch (e) {
      if (!_disposed && generation == _generation) {
        state = MenuState.failed;
        message = e is MenuFailure ? e.message : '未能讀取菜單，請重試。';
      }
    }
    _notify();
  }

  void search(String value, {bool fromSpeech = false}) {
    query = fromSpeech ? menuQueryFromSpeech(value) : value;
    section = null;
    _notify();
  }

  void selectSection(String? value) {
    section = value;
    _notify();
  }

  Future<String?> listen({bool allowNetwork = false}) async {
    if (!canSearch) return null;
    final generation = ++_generation;
    state = MenuState.preparing;
    voiceReadout = null;
    rawTranscript = '';
    partial = '';
    message = '正在準備咪高峰，震動後請講出想食的菜式。';
    _notify();
    try {
      final response = await reader.listen(
        allowNetwork: allowNetwork,
        onPhase: (phase) {
          if (_disposed || generation != _generation) return;
          state = switch (phase) {
            MenuSpeechPhase.preparing => MenuState.preparing,
            MenuSpeechPhase.listening => MenuState.listening,
            MenuSpeechPhase.finishing => MenuState.finishing,
          };
          message = switch (phase) {
            MenuSpeechPhase.preparing => '正在準備咪高峰，震動後請講出想食的菜式。',
            MenuSpeechPhase.listening => '正在聆聽，講完稍停便會自動搜尋。',
            MenuSpeechPhase.finishing => '收音完成，正在整理語音。',
          };
          _notify();
        },
        onPartial: (s) {
          if (!_disposed && generation == _generation) {
            if (s.trim().isNotEmpty) partial = s;
            _notify();
          }
        },
      );
      if (_disposed || generation != _generation) return null;
      state = MenuState.result;
      if (response.outcome == MenuSpeechOutcome.cancelled) return null;
      final text = response.text;
      rawTranscript = text;
      if (text.trim().isEmpty) {
        message = '未收到可用語音，請重試或輸入菜式。';
        voiceReadout = message;
        _notify();
        return null;
      }
      search(text, fromSpeech: true);
      message = '聽到：$text。搜尋：$query。';
      voiceReadout = searchReadout;
      _notify();
      return query;
    } catch (e) {
      if (_disposed || generation != _generation) return null;
      state = MenuState.result;
      message = e is MenuFailure ? e.message : '語音輸入失敗，可用文字搜尋。';
      _notify();
      if (e is MenuFailure && e.code == 'offline_speech_unavailable') rethrow;
      voiceReadout = message;
      return null;
    }
  }

  String get searchReadout {
    if (query.trim().isEmpty) return '請講出或輸入想食的菜式。';
    final matches = document?.search(query) ?? [];
    if (matches.isEmpty) return '呢次菜單辨識結果搵唔到$query。可能未拍齊或文字未讀清，可修改搜尋或重拍。';
    return '搵到 ${matches.length} 項$query。${matches.take(3).map((e) => e.spoken).join(" ")}${matches.length > 3 ? "其餘結果請在畫面逐項瀏覽。" : ""}';
  }

  Future<void> cancel() async {
    ++_generation;
    voiceReadout = null;
    await reader.cancel();
    if (_disposed) return;
    state = document == null ? MenuState.ready : MenuState.result;
    message = '已取消操作。';
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    reader.cancel();
    reader.dispose();
    super.dispose();
  }
}
