import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'menu_document.dart';

class MenuFailure implements Exception {
  const MenuFailure(this.message, {this.code = 'failed'});
  final String message, code;
}

enum MenuSpeechPhase { preparing, listening, finishing }

enum MenuSpeechOutcome { finalText, noSpeech, timeout, cancelled }

class MenuSpeechResult {
  const MenuSpeechResult(this.outcome, {this.text = ''});
  final MenuSpeechOutcome outcome;
  final String text;
  factory MenuSpeechResult.fromMap(Map? value) {
    if (value == null) {
      return const MenuSpeechResult(MenuSpeechOutcome.cancelled);
    }
    return MenuSpeechResult(
      MenuSpeechOutcome.values.byName(value['outcome'] as String),
      text: value['text'] as String? ?? '',
    );
  }
}

enum MenuImageSource { camera, library, scanner }

abstract class MenuReader {
  bool get supported;
  Future<MenuDocument?> read(
    MenuImageSource source, {
    required void Function() onRecognizing,
  });
  Future<MenuSpeechResult> listen({
    required bool allowNetwork,
    required void Function(String) onPartial,
    required void Function(MenuSpeechPhase) onPhase,
  });
  Future<void> finishListening();
  Future<void> cancel();
  void dispose();
}

class NativeMenuReader implements MenuReader {
  NativeMenuReader({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('hk.pathguide/menu') {
    _channel.setMethodCallHandler((call) async {
      final m = call.arguments as Map?;
      if (m?['requestId'] != _requestId) return;
      if (call.method == 'recognizing') _onRecognizing?.call();
      if (call.method == 'speechPhase') {
        _onPhase?.call(MenuSpeechPhase.values.byName(m?['phase'] as String));
      }
      if (call.method == 'speechPartial') {
        _onPartial?.call(m?['text'] as String? ?? '');
      }
    });
  }
  final MethodChannel _channel;
  String _requestId = '';
  static int _sequence = 0;
  void Function()? _onRecognizing;
  void Function(String)? _onPartial;
  void Function(MenuSpeechPhase)? _onPhase;
  @override
  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  Future<T?> _invoke<T>(String method, Map<String, Object> data) async {
    if (!supported) throw const MenuFailure('菜單閱讀目前先支援 iPhone。');
    try {
      return await _channel.invokeMethod<T>(method, data);
    } on PlatformException catch (e) {
      throw MenuFailure(e.message ?? '未能完成，請重試。', code: e.code);
    } on MissingPluginException {
      throw const MenuFailure('請重新安裝包含菜單功能的 App。');
    }
  }

  @override
  Future<MenuDocument?> read(
    MenuImageSource source, {
    required void Function() onRecognizing,
  }) async {
    _requestId = 'menu-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
    _onRecognizing = onRecognizing;
    final response = await _invoke<Map>('readMenu', {
      'requestId': _requestId,
      'source': source.name,
    });
    if (response == null) return null;
    return parseMenu(
      (response['lines'] as List)
          .map((l) => MenuLine.fromMap(l as Map))
          .toList(),
      pages: (response['pages'] as num).toInt(),
      truncated: response['truncated'] == true,
      warnings: (response['warnings'] as List? ?? const []).cast<String>(),
      engineVersion: response['ocrVersion'] as String? ?? 'unknown',
    );
  }

  @override
  Future<MenuSpeechResult> listen({
    required bool allowNetwork,
    required void Function(String) onPartial,
    required void Function(MenuSpeechPhase) onPhase,
  }) async {
    _requestId =
        'voice-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
    _onPartial = onPartial;
    _onPhase = onPhase;
    onPhase(MenuSpeechPhase.preparing);
    return MenuSpeechResult.fromMap(
      await _invoke<Map>('listenMenuQuery', {
        'requestId': _requestId,
        'allowNetwork': allowNetwork,
      }),
    );
  }

  @override
  Future<void> finishListening() =>
      _channel.invokeMethod<void>('finishMenuSpeech');
  @override
  Future<void> cancel() async {
    _requestId =
        'cancel-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
    try {
      await _channel.invokeMethod<void>('cancelMenu');
    } catch (_) {}
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}
