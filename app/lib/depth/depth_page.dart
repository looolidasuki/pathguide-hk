import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../settings/app_settings.dart';
import '../l10n/app_language.dart';
import '../vision/labels.dart';
import '../tts/announcer.dart';
import '../tts/flutter_tts_speaker.dart';
import 'depth_session.dart';
import 'depth_objects.dart';

class DepthPage extends StatefulWidget {
  const DepthPage({
    super.key,
    required this.settings,
    this.onBack,
    this.source,
    this.speaker,
    this.preview,
    this.initialObjects = true,
  });
  final AppSettings settings;
  final VoidCallback? onBack;
  final DepthSource? source;
  final Speaker? speaker;
  final Widget? preview;
  final bool initialObjects;
  @override
  State<DepthPage> createState() => _DepthPageState();
}

class _DepthPageState extends State<DepthPage> with WidgetsBindingObserver {
  late final _session = DepthSession(
    widget.source ??
        PlatformDepthSource(threshold: widget.settings.speakThreshold),
  );
  late bool _objects = widget.initialObjects;
  late final _speaker =
      widget.speaker ??
      FlutterTtsSpeaker(
        language: widget.settings.language,
        speechRate: widget.settings.speechSpeed.rate,
      );
  bool _foreground = true, _reading = false;
  int _speechGeneration = 0;
  String? _speechError;
  String? _speechKey;
  bool get _english => widget.settings.language == AppLanguage.english;
  String _t(String zh, String en) => _english ? en : zh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    if (_reading && (!_canRead || _speechKey != _readKey)) {
      unawaited(_stopSpeech());
    }
    setState(() {});
  }

  Future<void> _stopSpeech() async {
    ++_speechGeneration;
    _reading = false;
    try {
      await _speaker.stop();
    } catch (_) {}
  }

  Future<void> _toggle() async {
    await _stopSpeech();
    if (!mounted || !_foreground) return;
    _speechError = null;
    if (_session.running) {
      await _session.stop();
    } else {
      await _session.start(recognizeObjects: _objects);
    }
  }

  String get _status => switch (_session.status) {
    'idle' => _t('未開始測距', 'Measurement not started'),
    'starting' || 'waiting' => _t('正在準備深度資料', 'Preparing depth data'),
    'ready' => _t('中央表面估算距離', 'Estimated range to centre surface'),
    'objectsReady' => _t('目前物件（試驗）', 'Current objects (trial)'),
    'noObjects' => _t(
      '未辨識到物件，不代表前方暢通',
      'No objects detected; this does not establish clear space',
    ),
    'model' => _t(
      '物件辨識暫不可用，可關閉物件模式再試準星測距',
      'Object recognition unavailable. Turn off object mode to try crosshair range.',
    ),
    'stabilizing' ||
    'moving' => _t('請保持手機及準星穩定', 'Hold the phone and crosshair steady'),
    'tracking' => _t('追蹤未穩定，距離未知', 'Tracking unstable; range unknown'),
    'permission' => _t(
      '未獲相機權限，請到系統設定允許',
      'Camera access unavailable. Allow it in system settings.',
    ),
    'unsupported' => _t(
      '此裝置不支援 LiDAR 場景深度',
      'This device does not support LiDAR scene depth',
    ),
    'paused' => _t('已暫停，按開始重新量度', 'Paused. Press Start to measure again.'),
    'interrupted' => _t('相機中斷，請重新開始', 'Camera interrupted. Start again.'),
    'stale' => _t('資料過期，距離未知', 'Data expired; range unknown'),
    'failed' => _t('未能測距，請重新開始', 'Measurement unavailable. Start again.'),
    _ => _t('表面資料不足，距離未知', 'Insufficient surface data; range unknown'),
  };
  String get _distance => _session.rangeM == null
      ? _t('距離未知', 'Range unknown')
      : '${_t('約 ', 'About ')}${_session.rangeM!.toStringAsFixed(1)} ${_t('米', 'm')}';

  bool get _canRead =>
      _objects ? _session.objects.isNotEmpty : _session.rangeM != null;
  String get _readKey => _objects
      ? (_session.objects
                .map((e) => '${e.trackId}/${e.classId}/${e.rangeM != null}')
                .toList()
              ..sort())
            .join(',')
      : '${_session.rangeM != null}';
  String _name(int id) =>
      appText(labelOf(id)!.nameZh, widget.settings.language);
  String _location(double x) => x < .35
      ? _t('畫面左方', 'Left of image')
      : x > .65
      ? _t('畫面右方', 'Right of image')
      : _t('畫面中央', 'Centre of image');
  String get _summary => _objects
      ? _session.objects
            .take(3)
            .map(
              (object) =>
                  '${_location(object.box.center.dx)}，${_name(object.classId)}，'
                  '${object.rangeM == null ? _t('距離未知', 'Range unknown') : '${_t('框內表面約 ', 'Surface inside box about ')}${object.rangeM!.toStringAsFixed(1)} ${_t('米', 'm')}'}',
            )
            .join('。')
      : '${_t('準星所指表面，', 'Surface at the crosshair. ')}$_distance';

  Future<void> _read() async {
    final stopping = _stopSpeech();
    final generation = _speechGeneration;
    await stopping;
    if (!mounted ||
        !_foreground ||
        !_canRead ||
        generation != _speechGeneration) {
      return;
    }
    setState(() {
      _reading = true;
      _speechKey = _readKey;
      _speechError = null;
    });
    try {
      final speaker = _speaker;
      if (!MediaQuery.accessibleNavigationOf(context) &&
          speaker is FlutterTtsSpeaker) {
        await speaker.setAppLanguage(widget.settings.language);
        await speaker.setSpeechRate(widget.settings.speechSpeed.rate);
        await speaker.initialize();
        if (speaker.resolvedLanguage == null) throw StateError('no voice');
      }
      if (!mounted ||
          !_foreground ||
          generation != _speechGeneration ||
          !_canRead) {
        return;
      }
      // Read the latest value only after asynchronous voice initialization.
      final message = _summary;
      if (MediaQuery.accessibleNavigationOf(context)) {
        await SemanticsService.sendAnnouncement(
          View.of(context),
          message,
          Directionality.of(context),
        );
      } else {
        await speaker.speak(message);
      }
    } catch (_) {
      if (mounted && generation == _speechGeneration) {
        setState(
          () => _speechError = _t(
            '未能朗讀，可用讀屏查看。',
            'Speech unavailable. Use the screen reader.',
          ),
        );
      }
    } finally {
      if (mounted && generation == _speechGeneration) {
        setState(() => _reading = false);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      unawaited(_stopSpeech());
      unawaited(_session.stop());
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_changed);
    _session.dispose();
    unawaited(_stopSpeech());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back),
                    label: Text(_t('返回導航', 'Back to navigation')),
                  ),
                ),
                Text(
                  _t('物件與測距（試驗）', 'Objects and range (trial)'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  key: const ValueKey('depth-objects'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    _t('辨識物件並配對距離', 'Recognize objects and estimate range'),
                  ),
                  subtitle: Text(
                    _t(
                      '暫停後可切換至原本準星測距',
                      'Pause to switch to the original crosshair mode',
                    ),
                  ),
                  value: _objects,
                  onChanged: _session.running
                      ? null
                      : (value) => setState(() => _objects = value),
                ),
                Text(
                  _objects
                      ? _t(
                          '站定再按開始。物件名稱與框內表面距離均屬試驗結果；未有可靠深度時保留「距離未知」。',
                          'Stand still, then press Start. Object names and surface ranges are experimental. Unreliable depth remains unknown.',
                        )
                      : _t(
                          '站定，將中央準星對準實心表面，再按開始。只量鏡頭至表面的距離；不是物件最近邊緣、行走距離或可通行判斷。',
                          'Stand still, aim the centre crosshair at a solid surface, then press Start. Measures camera-to-surface range; not the nearest object edge, walking distance or free space.',
                        ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 220,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ExcludeSemantics(
                          child:
                              widget.preview ??
                              (!kIsWeb && Platform.isIOS
                                  ? const UiKitView(
                                      viewType: 'hk.pathguide/depth/preview',
                                    )
                                  : const ColoredBox(color: Colors.black)),
                        ),
                        if (!_objects)
                          const IgnorePointer(
                            child: Center(
                              child: Icon(
                                Icons.add,
                                color: Colors.yellow,
                                size: 42,
                              ),
                            ),
                          ),
                        if (_objects)
                          IgnorePointer(
                            child: ExcludeSemantics(
                              child: LayoutBuilder(
                                builder: (context, constraints) => Stack(
                                  children: [
                                    for (
                                      var i = 0;
                                      i < _session.objects.length;
                                      i++
                                    )
                                      Positioned.fromRect(
                                        rect: Rect.fromLTWH(
                                          _session.objects[i].box.left *
                                              constraints.maxWidth,
                                          _session.objects[i].box.top *
                                              constraints.maxHeight,
                                          _session.objects[i].box.width *
                                              constraints.maxWidth,
                                          _session.objects[i].box.height *
                                              constraints.maxHeight,
                                        ),
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                              color:
                                                  _session.objects[i].rangeM ==
                                                      null
                                                  ? Colors.orange
                                                  : Colors.cyan,
                                              width: 2,
                                            ),
                                          ),
                                          child: Align(
                                            alignment: Alignment.topLeft,
                                            child: ColoredBox(
                                              color: Colors.black,
                                              child: Text(
                                                ' ${i + 1} ',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 14,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    for (final object in _session.objects)
                                      if (object.samplePoint != null)
                                        Positioned(
                                          left:
                                              object.samplePoint!.dx *
                                                  constraints.maxWidth -
                                              5,
                                          top:
                                              object.samplePoint!.dy *
                                                  constraints.maxHeight -
                                              5,
                                          child: Container(
                                            width: 10,
                                            height: 10,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: object.rangeM == null
                                                  ? Colors.orange
                                                  : Colors.cyan,
                                              border: Border.all(
                                                color: Colors.black,
                                                width: 2,
                                              ),
                                            ),
                                          ),
                                        ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (!_session.running)
                          const ColoredBox(color: Color(0xBB000000)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(_status, key: const ValueKey('depth-status')),
                if (!_objects)
                  Text(
                    _distance,
                    key: const ValueKey('depth-range'),
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                if (_objects) ...[
                  for (var i = 0; i < _session.objects.length; i++)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '${i + 1}. ${_name(_session.objects[i].classId)} — ${_location(_session.objects[i].box.center.dx)}',
                            ),
                            Text(
                              _session.objects[i].rangeM == null
                                  ? _t('距離未知', 'Range unknown')
                                  : '${_t('框內表面約 ', 'Surface inside box about ')}${_session.objects[i].rangeM!.toStringAsFixed(1)} ${_t('米', 'm')}',
                            ),
                            Text(
                              depthReasonText(
                                _session.objects[i].reason,
                                english: _english,
                              ),
                            ),
                            if (_session.objects[i].validDepth != null)
                              Text(
                                '${_t('量程內高信心點：', 'High-confidence points in range: ')}'
                                '${_session.objects[i].validDepth}/${_session.objects[i].depthTotal}',
                              ),
                          ],
                        ),
                      ),
                    ),
                  Text(
                    _t(
                      '距離是框內可信表面的估算，不是整個物件最近邊緣，也不是可通行或碰撞判斷。朗讀最多讀出目前三個物件。',
                      'Range estimates a reliable surface inside a box, not the nearest object edge, clear space or collision risk. Reading covers up to three current objects.',
                    ),
                  ),
                  Text(
                    _t(
                      '框內圓點標示實際取樣位置；點數不是正確率。',
                      'The dot marks the actual sample location. Point counts are not accuracy.',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  _t(
                    '只在本機處理，不儲存或上傳畫面、深度或行走資料。玻璃、鏡面、細邊及混合表面可能不可靠；這版尚未完成量尺驗證。',
                    'Processed on device. No images, depth or walking data are saved or uploaded. Glass, mirrors, thin edges and mixed surfaces may be unreliable. Ruler validation is pending.',
                  ),
                ),
                if (_session.rangeM != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _t(
                      '量尺核對：從後置鏡頭位置至準星表面量度，分別試 0.5、1、2、3 米；記錄讀數及「未知」。',
                      'Ruler check: measure from the rear camera to the target surface at 0.5, 1, 2 and 3 metres. Record readings and unknown results.',
                    ),
                  ),
                ],
                if (_speechError != null) Text(_speechError!),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                key: const ValueKey('depth-toggle'),
                onPressed: _foreground ? _toggle : null,
                style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                child: Text(
                  _session.running
                      ? _t('暫停測距', 'Pause measurement')
                      : _t('開始測距', 'Start measurement'),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const ValueKey('depth-read'),
                onPressed: _reading
                    ? () {
                        unawaited(_stopSpeech());
                        setState(() {});
                      }
                    : _foreground && _canRead
                    ? _read
                    : null,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(48, 52),
                ),
                child: Text(
                  _reading
                      ? _t('停止朗讀', 'Stop reading')
                      : _objects
                      ? _t('朗讀目前物件', 'Read current objects')
                      : _t('朗讀目前距離', 'Read current range'),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
