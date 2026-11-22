import '../l10n/app_language.dart';

import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../settings/app_settings.dart';
import '../tts/announcer.dart' show Speaker;
import '../tts/flutter_tts_speaker.dart';
import 'menu_controller.dart';
import 'menu_document.dart';
import 'reading_sections.dart';
import 'menu_reader.dart';

/// 線上語音是哪一家（**廠商名**，讓句子自然接上「的線上語音服務」）。
///
/// 隱私說明必須點對名字：iOS 走 Apple 的語音服務，Android 走 Google 的。
///
/// 抽成頂層函數是為了**可測**：widget 測試若臨時改 `defaultTargetPlatform`，
/// 必須在測試體內復位（flutter_test 會在體尾檢查），很容易漏；
/// 純函數版本可以三個分支都直接斷言。
@visibleForTesting
String onlineVoiceVendorFor(TargetPlatform platform) => switch (platform) {
  TargetPlatform.iOS => 'Apple',
  TargetPlatform.android => 'Google',
  _ => '系統',
};

class MenuPage extends StatefulWidget {
  const MenuPage({
    super.key,
    required this.settings,
    required this.onBack,
    this.generalReading = false,
    this.reader,
    this.speaker,
  });
  final AppSettings settings;
  final VoidCallback onBack;
  final bool generalReading;
  final MenuReader? reader;
  final Speaker? speaker;
  @override
  State<MenuPage> createState() => _MenuPageState();
}

class _MenuPageState extends State<MenuPage> with WidgetsBindingObserver {
  late final MenuReadingController _menu = MenuReadingController(
    widget.reader ?? NativeMenuReader(includeGeneral: widget.generalReading),
  );
  late final Speaker _speaker =
      widget.speaker ??
      FlutterTtsSpeaker(speechRate: widget.settings.speechSpeed.rate);
  final _query = TextEditingController();
  final _searchFocus = FocusNode();
  bool _speaking = false, _outputBusy = false, _foreground = true;
  AppLifecycleState? _lastLifecycle;
  int _speechGeneration = 0;
  String? _speechMessage;
  String? _pendingReadout;
  int _voiceGeneration = 0;
  int _visibleLimit = 30;
  late bool _showMenu = !widget.generalReading;
  String _word = '';
  String? _lastSection;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _menu.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Flutter 回前景時會依序經過 paused → hidden → inactive → resumed。
    // 這個 hidden 是「正在回來」而不是「正在離開」。Android 系統相機返回時，
    // 原生端在 Flutter 回前景前已開始辨識（狀態不再是 acquiring），
    // 若把它當成離開而取消或清空待讀結果，辨識結果會被丟棄（2026-11-22 真機實測）。
    final returning =
        state == AppLifecycleState.hidden &&
        _lastLifecycle == AppLifecycleState.paused;
    _lastLifecycle = state;
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      final pending = _pendingReadout;
      _pendingReadout = null;
      if (pending != null) unawaited(_say(pending, literal: true));
    } else {
      unawaited(_stop());
      // An iOS permission sheet uses inactive. Keep its eventual response until resumed.
      if (!returning &&
          (state == AppLifecycleState.paused ||
              state == AppLifecycleState.detached ||
              state == AppLifecycleState.hidden)) {
        _pendingReadout = null;
        ++_voiceGeneration;
        // Native camera/picker presentation can hide Flutter. iOS cancels a
        // pending acquisition on UIApplication.didEnterBackgroundNotification.
        // Do not dismiss its camera merely because Flutter became hidden.
        if (_menu.state != MenuState.acquiring) unawaited(_menu.cancel());
      }
    }
  }

  Future<void> _stop() async {
    ++_speechGeneration;
    _speaking = false;
    _outputBusy = false;
    try {
      await _speaker.stop();
    } catch (_) {
      // A speech service failure must not block cancelling or taking a photo.
    }
    if (mounted) setState(() {});
  }

  Future<void> _say(String text, {bool literal = false}) async {
    if (!literal) text = context.tr(text);
    final stopping = _stop();
    final generation = _speechGeneration;
    await stopping;
    if (!mounted || generation != _speechGeneration) return;
    if (!_foreground) {
      _pendingReadout = text;
      return;
    }
    _outputBusy = true;
    try {
      if (MediaQuery.accessibleNavigationOf(context) &&
          MediaQuery.supportsAnnounceOf(context)) {
        await SemanticsService.sendAnnouncement(
          View.of(context),
          text,
          Directionality.of(context),
        );
      } else {
        if (_speaker is FlutterTtsSpeaker) {
          final tts = _speaker;
          await tts.setSpeechRate(widget.settings.speechSpeed.rate);
          await tts.setAppLanguage(widget.settings.language);
          await tts.initialize();
          if (!mounted || generation != _speechGeneration) return;
          if (tts.resolvedLanguage == null) {
            throw StateError('speech unavailable');
          }
          _speechMessage =
              widget.settings.language == AppLanguage.english || tts.isCantonese
              ? null
              : '此裝置未提供粵語，正使用其他中文語音。';
        }
        _speaking = true;
        if (mounted) setState(() {});
        await _speaker.speak(text);
      }
    } catch (_) {
      if (mounted && generation == _speechGeneration) {
        _speechMessage = '未能朗讀，可用 VoiceOver 或畫面查看結果。';
      }
    } finally {
      if (mounted && generation == _speechGeneration) {
        _speaking = false;
        _outputBusy = false;
        setState(() {});
      }
    }
  }

  Future<void> _read(MenuImageSource source) async {
    final generation = ++_voiceGeneration;
    _pendingReadout = null;
    await _stop();
    if (!mounted || !_foreground || generation != _voiceGeneration) return;
    _query.clear();
    _word = '';
    _lastSection = null;
    _showMenu = !widget.generalReading || source == MenuImageSource.scanner;
    _visibleLimit = 30;
    FocusManager.instance.primaryFocus?.unfocus();
    await _menu.read(source);
    if (!mounted || generation != _voiceGeneration) return;
    if (widget.generalReading) return;
    if (_menu.state == MenuState.failed ||
        _menu.document?.entries.isEmpty == true) {
      await _say(_menu.message);
    } else if (_menu.document?.warnings.isNotEmpty == true) {
      await _say(_menu.document!.warnings.join(' '));
    }
  }

  Future<void> _voice({bool allowNetwork = false}) async {
    final voiceGeneration = ++_voiceGeneration;
    _pendingReadout = null;
    await _stop();
    if (!mounted || !_foreground || voiceGeneration != _voiceGeneration) return;
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final query = await _menu.listen(allowNetwork: allowNetwork);
      if (!mounted || voiceGeneration != _voiceGeneration) return;
      if (query != null) {
        _query.text = query;
        _visibleLimit = 30;
      }
      final readout = _menu.voiceReadout;
      if (readout != null) await _say(readout);
    } on MenuFailure catch (e) {
      if (!mounted || e.code != 'offline_speech_unavailable') return;
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: AppText('使用 ${_onlineVoiceVendor()} 線上語音搜尋？'),
          content: AppText(
            '這部手機未提供離線粵語辨識。選擇繼續後，這次錄音可能由 ${_onlineVoiceVendor()} 的線上語音服務處理，需要網絡。菜單照片不會傳送到該服務。你亦可取消，直接輸入菜式。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const AppText('取消，改用文字'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const AppText('這次使用線上語音'),
            ),
          ],
        ),
      );
      if (yes == true && mounted) await _voice(allowNetwork: true);
    }
  }

  static String _onlineVoiceVendor() => onlineVoiceVendorFor(defaultTargetPlatform);

  /// 這個平台不支援菜單閱讀時，要說出**為什麼**與**在哪些平台可用**。
  static String _unsupportedReason(bool generalReading) =>
      switch (defaultTargetPlatform) {
    TargetPlatform.iOS => generalReading
        ? '閱讀文字支援 iOS 16 或以上的 iPhone。'
        : '菜單閱讀在 iPhone 需要 iOS 16 或以上。',
    TargetPlatform.android => '這部 Android 裝置未提供可用的文字辨識服務。',
    _ => '文字及菜單閱讀目前支援 iPhone 與 Android。',
  };
  void _search() {
    ++_voiceGeneration;
    _pendingReadout = null;
    _visibleLimit = 30;
    _menu.search(_query.text);
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(_say(_menu.searchReadout));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _menu.removeListener(_changed);
    _menu.dispose();
    unawaited(_speaker.stop());
    _query.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  String _readingStatus(MenuDocument? document) {
    if (_menu.state == MenuState.acquiring) return '正在開啟相機或相簿。';
    if (_menu.state == MenuState.recognizing) return '正在手機上辨識文字。';
    if (_menu.state == MenuState.failed) return _menu.message;
    if (document == null) return '拍攝或選取一張照片。';
    if (document.readingLines.isEmpty) return '暫未讀到文字，請重拍或選另一張照片。';
    return '辨識完成。請選擇要讀出的文字。';
  }

  List<Widget> _readingResults(MenuDocument document) {
    final result = readingSections(document.readingLines);
    final query = _word.trim().toLowerCase();
    final matches = result.lines
        .where((line) => line.text.toLowerCase().contains(query))
        .toList();
    return [
      if (document.readingLimited ||
          document.warnings.isNotEmpty ||
          result.lines.any((line) => line.confidence < .5))
        const AppText('可能只讀到部分文字，可查看現有內容或重拍。'),
      if (result.uncertainOrder) const AppText('版面次序待核對，請逐區閱讀。'),
      if (result.lines.isNotEmpty) ...[
        TextFormField(
          initialValue: _word,
          decoration: InputDecoration(labelText: context.tr('找字詞')),
          onChanged: (value) => setState(() {
            _word = value;
            _visibleLimit = 30;
          }),
        ),
        if (_lastSection case final text?)
          TextButton(
            onPressed: () => _say(text, literal: true),
            child: const AppText('重讀上一段'),
          ),
        if (matches.isEmpty) const AppText('找不到相符字詞。'),
        for (final line in matches.take(_visibleLimit))
          Card(
            child: ListTile(
              title: Text(line.text),
              subtitle: AppText(line.confidence < .5 ? '文字待核對' : '讀出此段'),
              onTap: () {
                setState(() => _lastSection = line.text);
                unawaited(_say(line.text, literal: true));
              },
            ),
          ),
        if (matches.length > _visibleLimit)
          OutlinedButton(
            onPressed: () => setState(() => _visibleLimit += 30),
            child: const AppText('顯示更多文字'),
          ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final document = _menu.document;
    final results = _menu.results;
    return Scaffold(
      appBar: AppBar(
        title: AppText(widget.generalReading ? '閱讀文字' : '菜單閱讀'),
        leading: BackButton(onPressed: widget.onBack),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.generalReading && document != null)
                OutlinedButton(
                  onPressed: _menu.busy
                      ? null
                      : () {
                          _pendingReadout = null;
                          unawaited(_stop());
                          setState(() {
                            _showMenu = !_showMenu;
                            _visibleLimit = 30;
                          });
                        },
                  child: AppText(_showMenu ? '返回文字結果' : '菜單查價'),
                ),
              OutlinedButton.icon(
                onPressed: _speaking || _outputBusy ? () => _stop() : null,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const AppText('停止 App 朗讀'),
              ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          key: const ValueKey('menu-page'),
          padding: const EdgeInsets.all(20),
          children: [
            if (!widget.generalReading)
              const AppText('先拍攝菜單，再講「我想食牛腩飯」。App 會搜尋已辨識文字，讀出可確認的標示價錢。'),
            const SizedBox(height: 12),
            if (!_menu.reader.supported)
              AppText(_unsupportedReason(widget.generalReading)),
            Semantics(
              // Result speech has one explicit output path; do not announce it twice.
              liveRegion: widget.generalReading && !_showMenu,
              child: AppText(
                widget.generalReading && !_showMenu
                    ? _readingStatus(document)
                    : _menu.message,
                key: const ValueKey('menu-status'),
              ),
            ),
            if (_speechMessage != null) AppText(_speechMessage!),
            if (_menu.state == MenuState.listening) ...[
              const SizedBox(height: 12),
              AppText(
                _menu.partial.isEmpty
                    ? '正在聆聽，只在這次搜尋錄音。'
                    : '聽到：${_menu.partial}',
              ),
              FilledButton.icon(
                onPressed: () => _menu.reader.finishListening(),
                icon: const Icon(Icons.done),
                label: const AppText('提早完成這次輸入'),
              ),
            ],
            if (_menu.busy)
              OutlinedButton(
                onPressed: () async {
                  ++_voiceGeneration;
                  _pendingReadout = null;
                  final cancelling = _menu.cancel();
                  await _stop();
                  await cancelling;
                },
                child: const AppText('取消目前操作'),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('capture-menu'),
              onPressed: _menu.reader.supported && !_menu.busy
                  ? () => _read(MenuImageSource.camera)
                  : null,
              icon: const Icon(Icons.document_scanner_outlined),
              label: AppText(
                widget.generalReading
                    ? (document == null ? '拍攝文字' : '重新拍攝文字')
                    : (document == null ? '拍攝菜單' : '重新拍攝菜單'),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _menu.reader.supported && !_menu.busy
                  ? () => _read(MenuImageSource.library)
                  : null,
              icon: const Icon(Icons.photo_library_outlined),
              label: AppText(widget.generalReading ? '選取照片' : '選取一張菜單照片'),
            ),
            if (_showMenu)
              TextButton(
                key: const ValueKey('scan-menu'),
                onPressed: _menu.reader.supported && !_menu.busy
                    ? () => _read(MenuImageSource.scanner)
                    : null,
                child: const AppText('文件掃描（選用，可拍多頁）'),
              ),
            if (!widget.generalReading)
              const AppText(
                '拍攝時將菜單文字放入鏡頭，盡量保持平穩及避免反光。密集菜單可近距離分區拍攝。使用系統相機拍照，再選擇使用照片；照片只用於本次讀字，不加入訓練上傳。',
              ),
            if (widget.generalReading && document != null) ...[
              if (!_showMenu) ..._readingResults(document),
              if (_showMenu && document.menuUnavailable)
                const AppText('部分菜單內容未能辨識。'),
            ],
            if (document != null && _showMenu) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const ValueKey('voice-menu-search'),
                onPressed: _menu.canSearch ? () => _voice() : null,
                icon: const Icon(Icons.mic_none),
                label: const AppText('語音搜尋菜式'),
              ),
              const SizedBox(height: 12),
              const ExcludeSemantics(child: AppText('想食的菜式')),
              const SizedBox(height: 8),
              Semantics(
                label: context.tr('想食的菜式'),
                child: TextField(
                  controller: _query,
                  focusNode: _searchFocus,
                  enabled: _menu.canSearch,
                  decoration: InputDecoration(
                    hintText: context.tr('例如：牛腩飯'),
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _menu.canSearch ? _search : null,
                child: const AppText('文字搜尋'),
              ),
              TextButton(
                onPressed: !_menu.busy
                    ? () {
                        _query.clear();
                        _menu.search('');
                      }
                    : null,
                child: const AppText('清除搜尋，返回全部分類'),
              ),
              Semantics(
                header: true,
                child: AppText(
                  '菜單分類',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const AppText('全部'),
                    selected: _menu.section == null,
                    onSelected: _menu.busy
                        ? null
                        : (_) => _menu.selectSection(null),
                  ),
                  ...document.sections.map(
                    (s) => ChoiceChip(
                      label: Text(s),
                      selected: _menu.section == s,
                      onSelected: _menu.busy
                          ? null
                          : (_) => _menu.selectSection(s),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              AppText('目前 ${results.length} 項。分類及價錢按照片文字整理，多欄或反光可能影響配對。'),
              if (results.isEmpty) const AppText('呢次辨識結果搵唔到相符內容，可修改搜尋或重拍。'),
              ...results
                  .take(_visibleLimit)
                  .map(
                    (entry) => Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            AppText(
                              entry.text,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            AppText(
                              '第 ${entry.page} 頁 · ${entry.section}${entry.uncertain ? " · 文字待核對" : ""}',
                            ),
                            if (entry.prices.isEmpty) const AppText('未能確認價錢'),
                            OutlinedButton(
                              onPressed: _menu.busy
                                  ? null
                                  : () => _say(entry.spoken),
                              child: AppText('重播 ${entry.name}'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              if (results.length > _visibleLimit)
                OutlinedButton(
                  onPressed: () => setState(() => _visibleLimit += 30),
                  child: const AppText('顯示更多菜單內容'),
                ),
              TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    scrollable: true,
                    title: const AppText('菜單辨識原文'),
                    content: SelectableText(document.original),
                    actions: [
                      TextButton(
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: document.diagnostics),
                          );
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: AppText('已複製辨識排查資料。')),
                            );
                          }
                        },
                        child: const AppText('複製排查資料'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const AppText('關閉'),
                      ),
                    ],
                  ),
                ),
                child: const AppText('查看辨識原文'),
              ),
            ],
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
