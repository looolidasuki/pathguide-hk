import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import 'route_memory_contract.dart';
import 'route_memory_mock_fixtures.dart';
import 'cross_floor_contract.dart';
import 'cross_floor_mock_fixtures.dart';
import 'cross_floor_mock_page.dart';
import 'route_library_screen.dart';

class RouteMemoryMockPage extends StatefulWidget {
  const RouteMemoryMockPage({
    super.key,
    required this.controller,
    required this.settings,
    required this.onBack,
  });

  final RouteMemoryController controller;
  final AppSettings settings;
  final VoidCallback onBack;

  @override
  State<RouteMemoryMockPage> createState() => _RouteMemoryMockPageState();
}

class _RouteMemoryMockPageState extends State<RouteMemoryMockPage>
    with WidgetsBindingObserver {
  final _nameController = TextEditingController();
  int _dialogGeneration = 0;
  bool _readRequested = false;

  void _openCrossFloor() {
    c.pause();
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _CrossFloorMockScreen(settings: widget.settings),
      ),
    );
  }

  void _openLibrary() {
    c.pause();
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RouteLibraryScreen(settings: widget.settings),
      ),
    );
  }

  RouteMemoryController get c => widget.controller;
  bool get _en => widget.settings.language == AppLanguage.english;

  String _t(String zh, String en) => _en ? en : zh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_controllerChanged);
  }

  void _controllerChanged() {
    _clearLive();
    _invalidateDialog();
  }

  @override
  void didUpdateWidget(covariant RouteMemoryMockPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(_controllerChanged);
      c.addListener(_controllerChanged);
      _controllerChanged();
    }
  }

  @override
  void dispose() {
    _invalidateDialog();
    c.removeListener(_controllerChanged);
    WidgetsBinding.instance.removeObserver(this);
    _nameController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      c.setForeground(true);
    } else {
      _dialogGeneration++;
      c.setForeground(false);
    }
  }

  void _clearLive() => _readRequested = false;

  void _invalidateDialog() => _dialogGeneration++;

  String _currentStatus() {
    final next = c.nextLandmark;
    return next == null
        ? _phaseStatus(c.phase, c.issue)
        : _t(
            '模擬下一路標：${_nodeName(next)}',
            'Mock next landmark: ${_nodeName(next)}',
          );
  }

  String _phaseStatus(RoutePhase phase, RouteIssue issue) {
    switch (phase) {
      case RoutePhase.idle:
        return _t('閒置：可開始模擬記錄', 'Idle: start a mock recording');
      case RoutePhase.recording:
        return _t(
          '模擬記錄中：可加入下一個樣例地標',
          'Mock recording: add the next sample landmark',
        );
      case RoutePhase.pausedRecording:
        return _t('模擬記錄已暫停：請手動繼續', 'Mock recording paused: resume manually');
      case RoutePhase.review:
        return _t('檢視記錄：命名後儲存', 'Review recording: name and save');
      case RoutePhase.saved:
        return _t('已儲存模擬路線：可選擇路線', 'Mock route saved: select a route');
      case RoutePhase.confirming:
        return _t(
          '確認起點與記錄方向後可開始',
          'Confirm start and recorded direction to begin',
        );
      case RoutePhase.replaying:
        return _t('模擬重行中：這不是真實導航', 'Mock retrace: this is not real navigation');
      case RoutePhase.unknown:
        return _t('模擬未辨識：請重新確認', 'Mock unrecognized: reconfirm');
      case RoutePhase.ambiguous:
        return _t('模擬位置有歧義：請重新確認', 'Mock ambiguous: reconfirm');
      case RoutePhase.pausedReplay:
        return _t(
          '模擬重行已暫停：請重新確認後再開始',
          'Mock retrace paused: reconfirm before restarting',
        );
      case RoutePhase.arrival:
        return _t('模擬到達候選：請明確確認', 'Mock arrival candidate: confirm explicitly');
      case RoutePhase.finished:
        return _t('模擬完成：這不是真實到達', 'Simulation complete: not a real arrival');
      case RoutePhase.deleted:
        return _t('模擬路線已刪除', 'Mock route deleted');
    }
  }

  String _issueText(RouteIssue issue) {
    switch (issue) {
      case RouteIssue.none:
        return '';
      case RouteIssue.unknown:
        return _t('原因：未辨識', 'Reason: unrecognized');
      case RouteIssue.ambiguous:
        return _t('原因：多個位置相似', 'Reason: ambiguous');
      case RouteIssue.direction:
        return _t('原因：方向不符', 'Reason: direction mismatch');
      case RouteIssue.stale:
        return _t('原因：過期', 'Reason: stale');
      case RouteIssue.incompatible:
        return _t('原因：不相容', 'Reason: incompatible');
    }
  }

  String _nodeName(LandmarkNode n) => _en ? n.nameEn : n.nameZh;

  void _onBack() {
    _invalidateDialog();
    _clearLive();
    c.pause();
    widget.onBack();
  }

  void _onStop() {
    _invalidateDialog();
    _clearLive();
    c.stop();
  }

  void _addLandmark() {
    final draft = c.draft;
    if (draft.length >= mockRouteLandmarks.length) return;
    for (final n in mockRouteLandmarks) {
      if (!draft.any((d) => d.id == n.id)) {
        c.recordLandmark(n);
        return;
      }
    }
  }

  void _step() {
    final next = c.nextLandmark;
    if (next == null) return;
    final ticket = c.beginObservation();
    if (ticket == null) return;
    c.acceptObservation(ticket, MockMatch.matched, nodeId: next.id);
  }

  void _inject(MockMatch match) {
    if (c.nextLandmark == null) return;
    final ticket = c.beginObservation();
    if (ticket == null) return;
    final nodeId = match == MockMatch.matched ? c.nextLandmark!.id : null;
    c.acceptObservation(ticket, match, nodeId: nodeId);
  }

  Future<void> _confirmDelete(RouteMemory route) async {
    final gen = ++_dialogGeneration;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('刪除路線？', 'Delete route?')),
        content: Text(
          _t('將刪除「${route.name}」。', 'This will delete "${route.name}".'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(_t('取消', 'Cancel')),
          ),
          TextButton(
            key: const ValueKey('route-confirm-delete'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(_t('刪除', 'Delete')),
          ),
        ],
      ),
    );
    if (!mounted || !c.foreground || gen != _dialogGeneration) return;
    if (ok == true) c.deleteRoute(route.id);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([c, widget.settings]),
      builder: (context, _) {
        final phase = c.phase;
        return SafeArea(
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  key: const ValueKey('route-content'),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _banner(),
                      const SizedBox(height: 12),
                      Text(
                        _t(
                          '不拍照、不定位；模擬路線只留記憶體，關閉 App 後清除。',
                          'No camera or location is used. Mock routes stay in memory until the app closes.',
                        ),
                      ),
                      const SizedBox(height: 12),
                      _btn(
                        'route-cross-floor',
                        _t('跨樓層與障礙提示模擬', 'Cross-floor and obstacle cue mock'),
                        _openCrossFloor,
                      ),
                      _btn(
                        'route-local-library',
                        _t('本機路線庫（樣例儲存）', 'Local routes (sample storage)'),
                        _openLibrary,
                      ),
                      _statusBlock(phase),
                      const SizedBox(height: 12),
                      ..._phaseControls(phase),
                      _btn(
                        'route-read',
                        _t('重讀目前狀態', 'Repeat current status'),
                        () => setState(() => _readRequested = true),
                      ),
                      if (c.selected != null &&
                          !{
                            RoutePhase.idle,
                            RoutePhase.saved,
                            RoutePhase.finished,
                            RoutePhase.deleted,
                          }.contains(phase))
                        _btn(
                          'route-delete',
                          _t('刪除所選路線', 'Delete selected route'),
                          () => _confirmDelete(c.selected!),
                          secondary: true,
                        ),
                      if (_readRequested) ...[
                        const SizedBox(height: 12),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _currentStatus(),
                            key: const ValueKey('route-readback'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              _bottomBar(),
            ],
          ),
        );
      },
    );
  }

  Widget _banner() {
    return Semantics(
      excludeSemantics: true,
      label: _t(
        '樣例模擬流程：無照片、無定位，路線只在 App 關閉前存在',
        'Mock flow: no photos, no location; routes only last until App closes',
      ),
      child: Container(
        width: double.infinity,
        color: Theme.of(context).colorScheme.secondary,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          _t('樣例模擬流程', 'Mock flow'),
          style: TextStyle(color: Theme.of(context).colorScheme.onSecondary),
        ),
      ),
    );
  }

  Widget _statusBlock(RoutePhase phase) {
    final issue = c.issue;
    final lines = <Widget>[
      Text(
        _phaseStatus(phase, issue),
        key: const ValueKey('route-status'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
    ];
    if (issue != RouteIssue.none) {
      lines.add(const SizedBox(height: 4));
      lines.add(Text(_issueText(issue)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines,
    );
  }

  List<Widget> _phaseControls(RoutePhase phase) {
    switch (phase) {
      case RoutePhase.idle:
      case RoutePhase.saved:
      case RoutePhase.finished:
      case RoutePhase.deleted:
        return [
          _btn(
            'route-start-recording',
            _t('開始模擬記錄', 'Start mock recording'),
            () {
              _nameController.clear();
              c.startRecording();
            },
          ),
          if (c.routes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_t('已儲存路線', 'Saved routes')),
            const SizedBox(height: 4),
            for (final r in c.routes) ...[
              _btn(
                'route-select-${r.id}',
                r.name,
                () => c.selectRoute(r.id),
                secondary: true,
              ),
              if (c.selected?.id == r.id)
                _btn(
                  'route-delete',
                  _t('刪除所選路線', 'Delete selected route'),
                  () => _confirmDelete(r),
                  secondary: true,
                ),
            ],
          ],
        ];
      case RoutePhase.recording:
        final canAdd = c.draft.length < mockRouteLandmarks.length;
        return [
          Text(_t('已加入 ${c.draft.length} / 3', '${c.draft.length} / 3 added')),
          if (canAdd)
            _btn(
              'route-add-landmark',
              _t('加入下一個地標', 'Add next landmark'),
              _addLandmark,
            ),
          _btn('route-pause', _t('暫停', 'Pause'), c.pause),
          if (c.draft.length >= 2)
            _btn('route-review', _t('檢視', 'Review'), c.finishRecording),
        ];
      case RoutePhase.pausedRecording:
        return [
          _btn(
            'route-resume-recording',
            _t('繼續記錄', 'Resume recording'),
            c.resumeRecording,
          ),
        ];
      case RoutePhase.review:
        return [
          TextField(
            key: const ValueKey('route-name'),
            controller: _nameController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: _t('路線名稱', 'Route name')),
          ),
          const SizedBox(height: 8),
          _btn('route-save', _t('儲存', 'Save'), () {
            c.saveRoute(_nameController.text);
            if (c.phase == RoutePhase.saved) _nameController.clear();
          }, enabled: _nameController.text.trim().isNotEmpty),
        ];
      case RoutePhase.confirming:
        final sel = c.selected;
        return [
          if (sel != null)
            Text(
              _t(
                '起點：${_nodeName(sel.nodes.first)}',
                'Start: ${_nodeName(sel.nodes.first)}',
              ),
            ),
          if (sel != null) Text(_t('記錄方向：正向', 'Recorded direction: forward')),
          CheckboxListTile(
            key: const ValueKey('route-confirm-start'),
            value: c.startConfirmed,
            onChanged: (v) => c.confirmStart(v ?? false),
            title: Text(_t('確認起點', 'Confirm start')),
          ),
          CheckboxListTile(
            key: const ValueKey('route-confirm-direction'),
            value: c.directionConfirmed,
            onChanged: (v) => c.confirmDirection(v ?? false),
            title: Text(_t('確認記錄方向', 'Confirm recorded direction')),
          ),
          _btn(
            'route-start-replay',
            _t('開始模擬重行', 'Start mock retrace'),
            c.startReplay,
            enabled: c.canStartReplay,
          ),
        ];
      case RoutePhase.replaying:
        final next = c.nextLandmark;
        return [
          if (next != null)
            Text(
              _t(
                '模擬下一地標：${_nodeName(next)}',
                'Mock next landmark: ${_nodeName(next)}',
              ),
            ),
          _btn('route-step', _t('模擬已到地標', 'Mock step matched'), _step),
          _btn(
            'route-unknown',
            _t('模擬未能認出位置', 'Simulate unknown location'),
            () => _inject(MockMatch.unknown),
          ),
          _btn(
            'route-ambiguous',
            _t('模擬多個相似位置', 'Simulate similar locations'),
            () => _inject(MockMatch.ambiguous),
          ),
          _btn(
            'route-wrong-direction',
            _t('模擬方向不符', 'Simulate wrong direction'),
            () => _inject(MockMatch.wrongDirection),
          ),
          _btn('route-pause', _t('暫停', 'Pause'), c.pause),
        ];
      case RoutePhase.unknown:
      case RoutePhase.ambiguous:
      case RoutePhase.pausedReplay:
        return [
          Text(
            _t(
              '請回到樣例起點，再確認已錄方向；本模擬會從起點重行。',
              'Return to the sample start and confirm the recorded direction; this mock restarts there.',
            ),
          ),
          _btn('route-reconfirm', _t('重新確認', 'Reconfirm'), c.reconfirm),
          _btn('route-pause', _t('暫停', 'Pause'), c.pause),
        ];
      case RoutePhase.arrival:
        return [
          Text(_t('模擬到達候選', 'Mock arrival candidate')),
          _btn(
            'route-confirm-arrival',
            _t('確認模擬到達', 'Confirm mock arrival'),
            c.confirmArrival,
          ),
          _btn('route-pause', _t('暫停', 'Pause'), c.pause),
        ];
    }
  }

  Widget _btn(
    String key,
    String label,
    VoidCallback onPressed, {
    bool secondary = false,
    bool enabled = true,
  }) {
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: secondary
          ? OutlinedButton(
              key: ValueKey(key),
              style: style,
              onPressed: enabled && c.foreground ? onPressed : null,
              child: Text(label),
            )
          : FilledButton(
              key: ValueKey(key),
              style: style,
              onPressed: enabled && c.foreground ? onPressed : null,
              child: Text(label),
            ),
    );
  }

  Widget _bottomBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: OutlinedButton(
                  key: const ValueKey('route-back'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 12,
                    ),
                  ),
                  onPressed: _onBack,
                  child: Text(_t('返回', 'Back')),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: FilledButton(
                  key: const ValueKey('route-stop'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 12,
                    ),
                  ),
                  onPressed: _onStop,
                  child: Text(_t('結束模擬', 'End mock')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Owns only the cross-floor preset lifetime. Existing N0 routes stay separate.
class _CrossFloorMockScreen extends StatefulWidget {
  const _CrossFloorMockScreen({required this.settings});
  final AppSettings settings;
  @override
  State<_CrossFloorMockScreen> createState() => _CrossFloorMockScreenState();
}

class _CrossFloorMockScreenState extends State<_CrossFloorMockScreen> {
  final _clock = MockJourneyClock();
  late final _controller = CrossFloorController(
    route: crossFloorFixture(),
    elapsed: _clock.elapsed,
  );
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: CrossFloorMockPage(
      controller: _controller,
      settings: widget.settings,
      onBack: () => Navigator.of(context).pop(),
    ),
  );
}
