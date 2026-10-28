import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../settings/app_settings.dart';
import '../tts/announcer.dart';
import '../tts/flutter_tts_speaker.dart';
import 'indoor_graph.dart';
import 'replay_scenarios.dart';

class GraphReplayPage extends StatefulWidget {
  const GraphReplayPage({
    super.key,
    required this.settings,
    this.onBack,
    this.speaker,
  });
  final AppSettings settings;
  final VoidCallback? onBack;
  final Speaker? speaker;
  @override
  State<GraphReplayPage> createState() => _GraphReplayPageState();
}

class _GraphReplayPageState extends State<GraphReplayPage>
    with WidgetsBindingObserver {
  ReplayScenario _scenario = replayScenarios.first;
  String _destination = 'N07';
  late GraphReplaySession _session;
  late final Speaker _speaker =
      widget.speaker ??
      FlutterTtsSpeaker(
        language: widget.settings.language,
        speechRate: widget.settings.speechSpeed.rate,
      );
  LandmarkMatch? _result;
  Timer? _timer;
  int _index = 0, _speechGeneration = 0;
  bool _playing = false, _foreground = true, _reading = false;
  String? _speechError;
  bool get _english => widget.settings.language == AppLanguage.english;
  String _t(String zh, String en) => _english ? en : zh;
  String _name(String id) {
    final node = demoIndoorGraph.nodes[id]!;
    return '$id ${_english ? node.nameEn : node.nameZh}';
  }

  bool get _finished => _index >= _scenario.events.length;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _newSession();
  }

  void _newSession() {
    _session = GraphReplaySession(
      graph: demoIndoorGraph,
      sessionId: _scenario.id,
      destination: _destination,
    );
    _index = 0;
    _result = null;
    _speechError = null;
  }

  Future<void> _stopSpeech() async {
    ++_speechGeneration;
    _reading = false;
    await _speaker.stop();
  }

  void _pause() {
    _timer?.cancel();
    _timer = null;
    unawaited(_stopSpeech());
    if (mounted) setState(() => _playing = false);
  }

  void _reset() {
    _pause();
    setState(_newSession);
  }

  void _step() {
    if (!_foreground || _finished) return;
    unawaited(_stopSpeech());
    final event = _scenario.events[_index];
    setState(() {
      _result = _session.observe(
        event.observation,
        receivedAt: event.receivedAt,
      );
      _index++;
      if (_finished) {
        _playing = false;
        _timer?.cancel();
        _timer = null;
      }
    });
  }

  void _togglePlay() {
    if (_playing) {
      _pause();
      return;
    }
    if (_finished || !_foreground) return;
    setState(() => _playing = true);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _step());
  }

  String get _status => _result == null
      ? _t('準備回放', 'Ready to replay')
      : switch (_result!.state) {
          MatchState.matched =>
            _result!.repeated
                ? _t('仍在同一樣例節點', 'Same sample node')
                : _result!.relocalized
                ? _t('重新對照已確認', 'Distant match confirmed')
                : _t('樣例路標已對照', 'Sample landmarks matched'),
          MatchState.unknown => _t(
            '路標不足，位置未知',
            'Insufficient landmarks; position unknown',
          ),
          MatchState.ambiguous => _t(
            '多個位置相似，暫不選定',
            'Ambiguous places; position withheld',
          ),
          MatchState.confirming => _t(
            '候選待下一筆新觀察確認',
            'Candidate needs another fresh observation',
          ),
          MatchState.ignored => _t(
            '舊回覆已忽略，保留較新結果',
            'Late response ignored; newer result retained',
          ),
          MatchState.outOfScope => _t(
            '場地、樓層或版本不符',
            'Building, floor or map version mismatch',
          ),
          MatchState.expired => _t(
            '觀察過期，撤回目前位置',
            'Expired observation; position withdrawn',
          ),
        };
  String get _position => _session.currentNode == null
      ? _t('目前位置：未知', 'Current position: unknown')
      : _t('目前對照：', 'Current match: ') + _name(_session.currentNode!);
  String get _summary {
    final next = _session.expectedNext;
    return '${_t('樣例回放。', 'Sample replay. ')}$_status。$_position。'
        '${next == null ? '' : _t('下一個graph路標：', 'Next graph landmark: ') + _name(next)}';
  }

  Future<void> _read() async {
    _pause();
    final stopping = _stopSpeech();
    final generation = _speechGeneration;
    await stopping;
    if (!mounted || !_foreground || generation != _speechGeneration) return;
    final text = _summary;
    setState(() {
      _reading = true;
      _speechError = null;
    });
    try {
      if (MediaQuery.accessibleNavigationOf(context)) {
        await SemanticsService.sendAnnouncement(
          View.of(context),
          text,
          Directionality.of(context),
        );
      } else {
        final speaker = _speaker;
        if (speaker is FlutterTtsSpeaker) {
          await speaker.setAppLanguage(widget.settings.language);
          await speaker.setSpeechRate(widget.settings.speechSpeed.rate);
          await speaker.initialize();
          if (!mounted || !_foreground || generation != _speechGeneration) {
            return;
          }
          if (speaker.resolvedLanguage == null) {
            throw StateError('speech unavailable');
          }
        }
        await speaker.speak(text);
      }
    } catch (_) {
      if (mounted && generation == _speechGeneration) {
        setState(
          () => _speechError = _t(
            '未能朗讀，可用讀屏查看結果。',
            'Speech unavailable. Use the screen reader to read the result.',
          ),
        );
      }
    } finally {
      if (mounted && generation == _speechGeneration) {
        setState(() => _reading = false);
      }
    }
  }

  Future<void> _pickScenario() async {
    _pause();
    final selected = await showModalBottomSheet<ReplayScenario>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .75,
          child: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _t('選擇回放情境', 'Choose a replay scenario'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (final scenario in replayScenarios)
                ListTile(
                  title: Text(_english ? scenario.titleEn : scenario.titleZh),
                  selected: scenario.id == _scenario.id,
                  onTap: () => Navigator.pop(context, scenario),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        _scenario = selected;
        _newSession();
      });
    }
  }

  Future<void> _pickDestination() async {
    _pause();
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .75,
          child: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _t(
                    '選擇樣例終點（重設回放）',
                    'Choose a sample destination (resets replay)',
                  ),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (final node in demoIndoorGraph.nodes.values)
                ListTile(
                  title: Text(_name(node.id)),
                  selected: node.id == _destination,
                  onTap: () => Navigator.pop(context, node.id),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        _destination = selected;
        _newSession();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _pause();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    unawaited(_stopSpeech());
    super.dispose();
  }

  Widget _button(
    String text,
    VoidCallback? action, {
    bool primary = false,
    Key? key,
  }) => primary
      ? FilledButton(
          key: key,
          onPressed: action,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          child: Text(text),
        )
      : OutlinedButton(
          key: key,
          onPressed: action,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
          ),
          child: Text(text),
        );

  @override
  Widget build(BuildContext context) {
    final event = _index == 0 ? null : _scenario.events[_index - 1];
    final matched = _session.currentNode;
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  onPressed: widget.onBack ?? () => Navigator.maybePop(context),
                  tooltip: _t('返回導航', 'Back to navigation'),
                  icon: const Icon(Icons.arrow_back),
                ),
                Expanded(
                  child: Text(
                    _t('室內路標回放', 'Indoor landmark replay'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              key: const ValueKey('graph-replay-content'),
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  _t(
                    '手動標註樣例；不會開相機、定位或上傳照片。',
                    'Hand-annotated samples. No camera, location tracking or photo upload.',
                  ),
                ),
                const SizedBox(height: 12),
                _button(
                  _t('情境：', 'Scenario: ') +
                      (_english ? _scenario.titleEn : _scenario.titleZh),
                  _pickScenario,
                ),
                Text(
                  _english ? _scenario.descriptionEn : _scenario.descriptionZh,
                ),
                const SizedBox(height: 8),
                _button(
                  _t('樣例終點：', 'Sample destination: ') + _name(_destination),
                  _pickDestination,
                ),
                const SizedBox(height: 12),
                Text(
                  _t(
                    '示意拓撲圖，沒有量測尺度',
                    'Schematic graph, without a measured scale',
                  ),
                ),
                Text(
                  _t(
                    '黃點：目前對照；紫點：終點；紅叉：封閉連線。',
                    'Yellow: current match. Purple: destination. Red cross: closed edge.',
                  ),
                ),
                ExcludeSemantics(
                  child: SizedBox(
                    height: 270,
                    child: CustomPaint(
                      painter: _GraphPainter(
                        demoIndoorGraph,
                        demoGraphLayout,
                        matched,
                        _destination,
                        _session.path,
                        _result?.candidates ?? [],
                        MediaQuery.textScalerOf(context),
                        Theme.of(context).textTheme.bodyMedium?.fontFamily,
                      ),
                    ),
                  ),
                ),
                Text(
                  _status,
                  key: const ValueKey('graph-match-status'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text(_position, key: const ValueKey('graph-position')),
                if (_session.lastTrustedNode != null && matched == null)
                  Text(
                    _t('上次確認（非目前位置）：', 'Last confirmed (not current): ') +
                        _name(_session.lastTrustedNode!),
                  ),
                if ((_result?.candidates.length ?? 0) > 1 ||
                    _result?.state == MatchState.confirming)
                  Text(
                    _t('候選：', 'Candidates: ') +
                        _result!.candidates.map(_name).join(' / '),
                  ),
                if (_result?.state == MatchState.matched)
                  Text(
                    _t(
                      '對上 ${_result!.matchedObjects} 個路標；不是準確率。',
                      '${_result!.matchedObjects} matching landmarks; not an accuracy percentage.',
                    ),
                  ),
                if (_result?.expectedNode != null &&
                    _result!.nodeId != _result!.expectedNode &&
                    !_result!.repeated)
                  Text(
                    _t(
                      '本筆與上筆預期不同，已核對其他路標。',
                      'This differs from the previous expectation; other landmarks were checked.',
                    ),
                  ),
                Text(
                  _session.path.isEmpty
                      ? _t(
                          '目前沒有可顯示的節點路線。',
                          'No node route is currently available.',
                        )
                      : _t(
                              '最少連線的樣例路線：',
                              'Sample route with the fewest edges: ',
                            ) +
                            _session.path.join(' → '),
                ),
                if (_session.expectedNext != null)
                  Text(
                    _t('下一個graph路標：', 'Next graph landmark: ') +
                        _name(_session.expectedNext!),
                  ),
                if (matched == _destination)
                  Text(
                    _t(
                      '已對照樣例終點；未代表真實到達。',
                      'Sample destination matched; this is not a real arrival.',
                    ),
                  ),
                const SizedBox(height: 12),
                Text(
                  _t(
                    '觀察 $_index / ${_scenario.events.length}',
                    'Observation $_index / ${_scenario.events.length}',
                  ),
                ),
                if (event != null) ...[
                  Text(
                    _t(
                      '本筆拍攝序號：${event.observation.sequence}；樓層：${event.observation.floor}',
                      'Capture sequence: ${event.observation.sequence}; floor: ${event.observation.floor}',
                    ),
                  ),
                  Text(
                    _t('觀察路標：', 'Observed landmarks: ') +
                        event.observation.landmarks.join(' / '),
                  ),
                  Text(
                    _t(
                      '收到時資料年齡：${event.receivedAt.difference(event.observation.capturedAt).inSeconds} 秒',
                      'Age on receipt: ${event.receivedAt.difference(event.observation.capturedAt).inSeconds} seconds',
                    ),
                  ),
                ],
                Text(
                  _t('按拍攝排序的佇列：', 'Queue in capture order: ') +
                      _session.observations.map((o) => o.sequence).join(' → '),
                  key: const ValueKey('graph-observation-queue'),
                ),
                const SizedBox(height: 12),
                Text(
                  _t(
                    '自動回放每秒顯示一筆樣例觀察；朗讀請按「朗讀結果」。沒有距離、方向或避障指令。',
                    'Automatic replay displays one sample observation per second. Use Read result for speech. No distance, turn or avoidance instructions.',
                  ),
                ),
                if (_speechError != null) Text(_speechError!),
              ],
            ),
          ),
          Material(
            elevation: 8,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _button(
                          _t('下一筆觀察', 'Next observation'),
                          _finished || _playing ? null : _step,
                          primary: true,
                          key: const ValueKey('graph-step'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _button(
                          _playing
                              ? _t('暫停回放', 'Pause replay')
                              : _t('自動回放', 'Play replay'),
                          _finished ? null : _togglePlay,
                          key: const ValueKey('graph-play'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _button(
                          _t('重新開始', 'Restart'),
                          _reset,
                          key: const ValueKey('graph-reset'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _button(
                          _reading
                              ? _t('停止朗讀', 'Stop speech')
                              : _t('朗讀結果', 'Read result'),
                          _reading
                              ? () {
                                  unawaited(_stopSpeech());
                                  setState(() {});
                                }
                              : _read,
                          key: const ValueKey('graph-read'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter(
    this.graph,
    this.layout,
    this.current,
    this.destination,
    this.path,
    this.candidates,
    this.scaler,
    this.fontFamily,
  );
  final IndoorGraph graph;
  final Map<String, (double, double)> layout;
  final String? current;
  final String destination;
  final List<String> path, candidates;
  final TextScaler scaler;
  final String? fontFamily;
  @override
  void paint(Canvas canvas, Size size) {
    Offset point(String id) {
      final (x, y) = layout[id]!;
      return Offset(20 + x * (size.width - 40), 24 + y * (size.height - 48));
    }

    bool selected(IndoorEdge edge) {
      for (var i = 1; i < path.length; i++) {
        if ((path[i - 1] == edge.from && path[i] == edge.to) ||
            (path[i - 1] == edge.to && path[i] == edge.from)) {
          return true;
        }
      }
      return false;
    }

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final edge in graph.edges) {
      canvas.drawLine(
        point(edge.from),
        point(edge.to),
        Paint()
          ..color = !edge.open
              ? Colors.redAccent
              : selected(edge)
              ? Colors.cyanAccent
              : Colors.blueGrey
          ..strokeWidth = selected(edge) ? 4 : 2,
      );
      if (!edge.open) {
        final center = (point(edge.from) + point(edge.to)) / 2;
        canvas.drawLine(
          center - const Offset(5, 5),
          center + const Offset(5, 5),
          Paint()
            ..color = Colors.redAccent
            ..strokeWidth = 3,
        );
        canvas.drawLine(
          center - const Offset(5, -5),
          center + const Offset(5, -5),
          Paint()
            ..color = Colors.redAccent
            ..strokeWidth = 3,
        );
      }
    }
    for (final node in graph.nodes.values) {
      final color = node.id == current
          ? Colors.amberAccent
          : candidates.contains(node.id) && current == null
          ? Colors.orangeAccent
          : node.id == destination
          ? Colors.purpleAccent
          : Colors.cyan;
      canvas.drawCircle(
        point(node.id),
        node.id == current ? 9 : 6,
        Paint()..color = color,
      );
      final text = TextPainter(
        text: TextSpan(
          text: node.id,
          style: TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontFamily: fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      text.paint(
        canvas,
        point(node.id) + Offset(-text.width / 2, -text.height - 12),
      );
      text.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) =>
      old.current != current ||
      old.destination != destination ||
      old.path.join(',') != path.join(',') ||
      old.candidates.join(',') != candidates.join(',') ||
      old.scaler != scaler ||
      old.fontFamily != fontFamily;
}
