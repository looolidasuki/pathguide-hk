import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import 'cross_floor_contract.dart';
import 'cross_floor_mock_fixtures.dart';

class CrossFloorMockPage extends StatefulWidget {
  const CrossFloorMockPage({
    super.key,
    required this.controller,
    required this.settings,
    required this.onBack,
  });

  final CrossFloorController controller;
  final AppSettings settings;
  final VoidCallback onBack;

  @override
  State<CrossFloorMockPage> createState() => _CrossFloorMockPageState();
}

class _CrossFloorMockPageState extends State<CrossFloorMockPage>
    with WidgetsBindingObserver {
  bool _readRequested = false;

  bool get _en => widget.settings.language == AppLanguage.english;
  String _t(String zh, String en) => _en ? en : zh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onController);
  }

  void _onController() {
    if (_readRequested) _readRequested = false;
  }

  @override
  void didUpdateWidget(covariant CrossFloorMockPage old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
      _readRequested = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.controller.setForeground(true);
    } else {
      widget.controller.setForeground(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onController);
    widget.controller.pause();
    super.dispose();
  }

  static const Map<FloorPhase, (String, String)> _phaseNames = {
    FloorPhase.idle: ('未開始', 'Not started'),
    FloorPhase.walkingOnFloor: ('同層步行', 'Walking on floor'),
    FloorPhase.approachingConnector: ('接近轉層點', 'Approaching connector'),
    FloorPhase.transitioning: ('轉層中', 'Transitioning'),
    FloorPhase.awaitingFloorConfirmation: (
      '等待確認樓層',
      'Awaiting floor confirmation',
    ),
    FloorPhase.relocalizingExit: ('重新定位出口', 'Relocalizing exit'),
    FloorPhase.unknown: ('狀態未知', 'Unknown state'),
    FloorPhase.paused: ('已暫停', 'Paused'),
    FloorPhase.arrival: ('終點候選（待確認）', 'Arrival (pending confirmation)'),
    FloorPhase.finished: ('已完成', 'Finished'),
    FloorPhase.deleted: ('路線已刪除', 'Route deleted'),
  };

  static const Map<String, (String, String)> _reasons = {
    'none': ('正常', 'Normal'),
    'manualReconfirmationRequired': (
      '需手動重新確認',
      'Manual reconfirmation required',
    ),
    'perceptionUnavailable': ('感測不可用', 'Sensing unavailable'),
    'syntheticObstacle': ('合成障礙提示', 'Synthetic obstacle notice'),
    'nextLandmark': ('前往下一個地標', 'Proceed to next landmark'),
    'locationExpired': ('定位已過期', 'Location expired'),
    'approachingConnector': ('前往轉層點', 'Head to the connector'),
    'transitioning': ('轉層中，等待出口證據', 'Transitioning; await exit evidence'),
    'awaitingFloorConfirmation': ('確認樓層', 'Confirm floor'),
    'relocalizingExit': ('確認出口與方向', 'Confirm exit and direction'),
    'confirmArrival': ('確認到達', 'Confirm arrival'),
    'confirmFloor': ('確認樓層', 'Confirm floor'),
    'wrongFloor': ('樓層不符', 'Floor mismatch'),
    'ambiguousExit': ('出口證據不明確', 'Ambiguous exit evidence'),
    'confirmExitAndDirection': ('確認出口與方向', 'Confirm exit and direction'),
    'wrongExitOrDirection': ('出口或方向不符', 'Wrong exit or direction'),
    'wrongNodeOrFloor': ('地標或樓層不符', 'Wrong landmark or floor'),
    'invalidLocation': ('定位無效', 'Invalid location'),
    'matched': ('已配對', 'Matched'),
    'idle': ('尚未開始模擬', 'Mock not started'),
    'unknown': ('位置未知，請重新確認', 'Location unknown; reconfirm'),
    'ambiguous': ('位置有歧義，請重新確認', 'Ambiguous location; reconfirm'),
    'wrongDirection': ('方向不符，請重新確認', 'Direction mismatch; reconfirm'),
    'paused': ('已暫停，請手動重新確認', 'Paused; manually reconfirm'),
    'arrival': ('終點候選，等待確認', 'Destination candidate; confirm'),
    'finished': ('模擬完成', 'Mock finished'),
    'deleted': ('模擬路線已刪除', 'Mock route deleted'),
  };

  String _phaseLabel(FloorPhase p) {
    final v = _phaseNames[p] ?? ('未知', 'Unknown');
    return _en ? v.$2 : v.$1;
  }

  String _reasonLabel(String r) {
    final v = _reasons[r];
    if (v == null) return _t('狀態更新', 'Status update');
    return _en ? v.$2 : v.$1;
  }

  String _floorLabel(FloorRef? f) {
    if (f == null) return _t('未知', 'Unknown');
    return f.label;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final settings = widget.settings;
    return SafeArea(
      child: AnimatedBuilder(
        animation: Listenable.merge([c, settings]),
        builder: (context, _) => Column(
          children: [
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.secondary,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                _t('跨樓層模擬', 'Cross-floor MOCK'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSecondary,
                ),
              ),
            ),
            Expanded(child: _body(context, c)),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: OutlinedButton(
                        key: const ValueKey('p0-back'),
                        onPressed: () {
                          c.pause();
                          widget.onBack();
                        },
                        child: Text(_t('返回', 'Back')),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: FilledButton(
                        key: const ValueKey('p0-pause'),
                        onPressed: c.pause,
                        child: Text(_t('暫停', 'Pause')),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, CrossFloorController c) {
    final g = c.guidance;
    final n = g?.node;
    final nextName = n == null ? null : (_en ? n.nameEn : n.nameZh);
    final readText = !_readRequested
        ? null
        : (g == null
              ? _t('無指引', 'No guidance')
              : '${_reasonLabel(g.reason)}${nextName == null ? '' : ': $nextName'}'
                    '${g.floor == null ? '' : ' (${g.floor!.label})'}');
    final phase = c.phase;
    final canStart =
        c.foreground &&
        {
          FloorPhase.idle,
          FloorPhase.paused,
          FloorPhase.unknown,
        }.contains(phase);
    final canReloc =
        c.foreground && {FloorPhase.paused, FloorPhase.unknown}.contains(phase);
    final canPropose =
        phase == FloorPhase.transitioning ||
        phase == FloorPhase.awaitingFloorConfirmation;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _t(
              '合成 G → 3F 路線；無相機、定位或 TTS。按鈕注入事件，時間已凍結；只留記憶體。',
              'Synthetic G → 3F route. No camera, location or TTS. Buttons inject events with frozen time; memory only.',
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _t('目前階段：', 'Current phase: ') + _phaseLabel(phase),
            key: const ValueKey('p0-header'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text('${_t('實際樓層', 'Actual floor')}: ${_floorLabel(c.actualFloor)}'),
          Text(
            '${_t('預期樓層', 'Expected floor')}: ${_floorLabel(c.expectedFloor)}',
          ),
          Text(
            '${_t('候選樓層', 'Candidate floor')}: ${_floorLabel(c.candidateFloor)}',
          ),
          Text('${_t('狀態', 'Issue')}: ${_reasonLabel(c.issue)}'),
          Text(
            '${_t('指引', 'Guidance')}: '
            '${g == null ? _t('無', 'None') : _reasonLabel(g.reason)}',
          ),
          if (nextName != null)
            Text('${_t('下一地標', 'Next landmark')}: $nextName'),
          const SizedBox(height: 8),
          _btn(
            'p0-start',
            '確認 G 起點及方向',
            'Confirm G start + direction',
            canStart
                ? () => c.startAt(
                    'g-entry',
                    floorConfirmed: true,
                    directionConfirmed: true,
                  )
                : null,
          ),
          _btn(
            'p0-relocalize',
            '手動確認 3F 出口及方向',
            'Manually confirm 3F exit + direction',
            canReloc
                ? () => c.startAt(
                    '3-exit',
                    floorConfirmed: true,
                    directionConfirmed: true,
                  )
                : null,
          ),
          _btn(
            'p0-next',
            '模擬到下一路標',
            'Mock next landmark',
            phase != FloorPhase.walkingOnFloor
                ? null
                : () {
                    if (c.phase != FloorPhase.walkingOnFloor) return;
                    final nn = c.nextNode;
                    if (nn == null) return;
                    final t = c.observe(EvidenceChannel.location);
                    if (t == null) return;
                    c.match(
                      t,
                      FloorMatch.matched,
                      nodeId: nn.id,
                      floor: nn.floor,
                    );
                  },
          ),
          _btn(
            'p0-enter',
            '進入轉層',
            'Enter connector',
            phase == FloorPhase.approachingConnector ? c.enterConnector : null,
          ),
          _btn(
            'p0-wrong',
            '注入 2F 出口',
            'Inject 2F exit',
            !canPropose
                ? null
                : () {
                    final t = c.observe(EvidenceChannel.location);
                    if (t == null) return;
                    c.proposeExit(t, mockSecond);
                  },
          ),
          _btn(
            'p0-third',
            '注入 3F 出口',
            'Inject 3F exit',
            !canPropose
                ? null
                : () {
                    final t = c.observe(EvidenceChannel.location);
                    if (t == null) return;
                    c.proposeExit(t, mockThird);
                  },
          ),
          _btn(
            'p0-ambiguous',
            '注入不明確出口',
            'Inject ambiguous exit',
            !canPropose
                ? null
                : () {
                    final t = c.observe(EvidenceChannel.location);
                    if (t == null) return;
                    c.proposeExit(t, mockThird, ambiguous: true);
                  },
          ),
          _btn(
            'p0-confirm-floor',
            '確認樓層',
            'Confirm floor',
            c.canConfirmFloor ? c.confirmFloor : null,
          ),
          _btn(
            'p0-exit',
            '確認 3F 出口及方向',
            'Confirm 3F exit + direction',
            phase != FloorPhase.relocalizingExit
                ? null
                : () {
                    if (c.phase != FloorPhase.relocalizingExit) return;
                    final t = c.observe(EvidenceChannel.location);
                    if (t == null) return;
                    c.confirmExit(
                      t,
                      nodeId: '3-exit',
                      floor: mockThird,
                      directionConfirmed: true,
                    );
                  },
          ),
          _btn('p0-urgent', '注入緊急事件', 'Inject urgent event', () {
            final t = c.observe(EvidenceChannel.perception);
            if (t == null) return;
            c.perceive(
              PerceptionFrame(
                t,
                PerceptionState.urgent,
                objectLabel: 'sample box',
              ),
            );
          }),
          _btn('p0-clear', '注入：暫無模擬警示', 'Inject: no current mock alert', () {
            final t = c.observe(EvidenceChannel.perception);
            if (t == null) return;
            c.perceive(PerceptionFrame(t, PerceptionState.noAlert));
          }),
          _btn('p0-unavailable', '注入感測不可用', 'Inject sensing unavailable', () {
            final t = c.observe(EvidenceChannel.perception);
            if (t == null) return;
            c.perceive(PerceptionFrame(t, PerceptionState.unavailable));
          }),
          _btn(
            'p0-arrival',
            '確認到達',
            'Confirm arrival',
            phase == FloorPhase.arrival ? c.confirmArrival : null,
          ),
          _btn(
            'p0-delete',
            '刪除路線',
            'Delete route',
            phase == FloorPhase.deleted ? null : c.deleteRoute,
          ),
          _btn('p0-read', '重播模擬指引', 'Repeat mock guidance', () {
            setState(() => _readRequested = true);
          }),
          if (readText != null)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(readText, key: const ValueKey('p0-readback')),
              ),
            ),
        ],
      ),
    );
  }

  Widget _btn(String key, String zh, String en, VoidCallback? action) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: OutlinedButton(
          key: ValueKey(key),
          onPressed: action,
          child: Text(_t(zh, en), textAlign: TextAlign.center),
        ),
      ),
    );
  }
}
