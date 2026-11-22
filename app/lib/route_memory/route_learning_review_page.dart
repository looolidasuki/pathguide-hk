import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'encrypted_route_store.dart';
import 'route_learning_store.dart';
import 'route_package.dart';

class RouteLearningReviewPage extends StatefulWidget {
  const RouteLearningReviewPage({
    super.key,
    required this.openStore,
    required this.routes,
    required this.routeId,
    required this.english,
  });

  final Future<RouteLearningStore> Function() openStore;
  final EncryptedRouteStore routes;
  final String routeId;
  final bool english;

  @override
  State<RouteLearningReviewPage> createState() =>
      _RouteLearningReviewPageState();
}

class _RouteLearningReviewPageState extends State<RouteLearningReviewPage>
    with WidgetsBindingObserver {
  final _reviewer = TextEditingController();
  final _reason = TextEditingController();
  final _floor = TextEditingController();
  List<String> _ids = [];
  List<RoutePoint> _nodes = [];
  Map<String, dynamic>? _record;
  MemoryImage? _photo;
  Timer? _expiry;
  String? _node;
  LearningReview? _decision;
  bool _direction = false, _exit = false, _busy = true, _foreground = true;
  int _index = 0, _generation = 0;
  String? _error;
  late RouteLearningStore _store;

  String _t(String zh, String en) => widget.english ? en : zh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load(0);
  }

  void _clearPhoto() {
    _expiry?.cancel();
    _expiry = null;
    _photo?.evict();
    _photo = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_foreground) {
      _foreground = true;
      _load(_index);
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _foreground = false;
      _generation++;
      setState(() {
        _clearPhoto();
        _record = null;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _clearPhoto();
    _reviewer.dispose();
    _reason.dispose();
    _floor.dispose();
    super.dispose();
  }

  bool _current(int generation) =>
      mounted && _foreground && generation == _generation;

  Future<void> _load(int requested) async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _clearPhoto();
      _record = null;
      _node = null;
      _decision = null;
      _direction = _exit = false;
      _reason.clear();
      _floor.clear();
    });
    try {
      _store = await widget.openStore();
      await _store.cleanup();
      final ids = await _store.list(routeId: widget.routeId);
      final index = ids.isEmpty ? 0 : requested.clamp(0, ids.length - 1);
      final record = ids.isEmpty ? null : await _store.read(ids[index]);
      var nodes = <RoutePoint>[];
      if (record != null) {
        try {
          final snapshot = await widget.routes.read(
            widget.routeId,
            version: record['routeVersion'] as int,
          );
          nodes = snapshot.document.nodes;
        } on RouteStoreFailure {
          // A pruned source version can still be reviewed as incomplete or deleted.
        }
      }
      if (!_current(generation)) return;
      setState(() {
        _ids = ids;
        _index = index;
        _record = record;
        _nodes = nodes;
        _photo = record == null
            ? null
            : MemoryImage(base64Decode(record['jpeg'] as String));
      });
      if (record != null) {
        final remaining =
            (record['expires'] as int) - _store.clock().millisecondsSinceEpoch;
        _expiry = Timer(Duration(milliseconds: remaining), () {
          if (_current(generation)) unawaited(_load(index));
        });
      }
    } catch (_) {
      if (_current(generation)) {
        _error = _t('未能讀取候選，請重試。', 'Could not load candidates. Try again.');
      }
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _update({bool delete = false}) async {
    final record = _record;
    if (_busy || record == null) return;
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = record['id'] as String;
      if (delete) {
        await _store.deleteCandidate(id);
      } else {
        await _store.review(
          id,
          expectedRevision: record['revision'] as int,
          decision: _decision!,
          reviewer: _reviewer.text,
          reason: _reason.text,
          node: _node,
          floor: _floor.text,
          directionChecked: _direction,
          exitChecked: _exit,
          isCurrent: () => _current(generation),
        );
      }
      if (_current(generation)) await _load(_index);
    } on LearningStoreFailure catch (error) {
      if (!_current(generation)) return;
      if (['conflict', 'missing', 'expired'].contains(error.code)) {
        await _load(_index);
      } else {
        _showUpdateError();
      }
    } catch (_) {
      if (_current(generation)) _showUpdateError();
    }
  }

  void _showUpdateError() => setState(() {
    _busy = false;
    _error = _t('未能保存更改，請重試。', 'Could not save the change. Try again.');
  });

  String _state(String? state) => switch (state) {
    'candidate' => _t('有候選路標', 'Candidate match'),
    'ambiguous' => _t('比對有歧義', 'Ambiguous match'),
    'unknown' => _t('未辨認', 'Unknown match'),
    'verified' => _t('已核實', 'Verified'),
    'needsInformation' => _t('待補資料', 'Needs information'),
    'rejected' => _t('已拒絕', 'Rejected'),
    _ => _t('待覆核', 'Pending review'),
  };

  String _name(String? id) {
    for (final node in _nodes) {
      if (node.id == id) return _t(node.nameZh, node.nameEn);
    }
    return id ?? _t('無', 'None');
  }

  bool get _canSave =>
      !_busy &&
      _decision != null &&
      _reviewer.text.trim().isNotEmpty &&
      _reason.text.trim().length >= 5 &&
      (_decision != LearningReview.verified ||
          (_node != null &&
              _floor.text.trim().isNotEmpty &&
              _direction &&
              _exit));

  @override
  Widget build(BuildContext context) {
    final record = _record;
    return Scaffold(
      appBar: AppBar(title: Text(_t('覆核路標候選', 'Review landmark candidates'))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_error case final error?)
                Semantics(liveRegion: true, child: Text(error)),
              if (!_busy && _error != null)
                OutlinedButton(
                  onPressed: () => _load(_index),
                  child: Text(_t('重新讀取', 'Reload')),
                ),
              if (!_busy && _error == null && record == null)
                Text(
                  _t('此路線沒有未到期的候選。', 'This route has no unexpired candidates.'),
                ),
              if (_foreground && record != null) ...[
                Text(
                  _t(
                    '候選 ${_index + 1}／${_ids.length}',
                    'Candidate ${_index + 1} of ${_ids.length}',
                  ),
                ),
                Text(
                  _t(
                    '路線版本 ${record['routeVersion']}',
                    'Route version ${record['routeVersion']}',
                  ),
                ),
                if (_photo case final photo?)
                  Image(
                    image: photo,
                    fit: BoxFit.contain,
                    semanticLabel: _t('候選路標相片', 'Candidate landmark photo'),
                  ),
                Text(
                  '${_t('原比對結果', 'Original match')} · ${_state(record['prediction'] as String?)}',
                ),
                Text(
                  '${_t('原比對路標', 'Matched landmark')} · ${_name(record['predictedNode'] as String?)}',
                ),
                Text(
                  '${_t('當時所選路標', 'Landmark selected during replay')} · ${_name(record['requestedNode'] as String?)}',
                ),
                Text(
                  '${_t('覆核狀態', 'Review status')} · ${_state(record['state'] as String?)}',
                ),
                if ((record['reviews'] as List).lastOrNull
                    case final Map review) ...[
                  if (review['node'] case final String node)
                    Text(
                      '${_t('已核實路標及樓層', 'Reviewed landmark and floor')} · ${_name(node)} · ${review['floor']}',
                    ),
                  Text('${_t('覆核原因', 'Review reason')} · ${review['reason']}'),
                ],
                OutlinedButton(
                  onPressed: _busy || _index == 0
                      ? null
                      : () => _load(_index - 1),
                  child: Text(_t('上一個候選', 'Previous candidate')),
                ),
                OutlinedButton(
                  onPressed: _busy || _index + 1 >= _ids.length
                      ? null
                      : () => _load(_index + 1),
                  child: Text(_t('下一個候選', 'Next candidate')),
                ),
                Text(
                  _t(
                    '請按你在現場核實的資料填寫。如無法確認，選擇待補資料或拒絕。',
                    'Use what you verified at the site. If you are unsure, select Needs information or Rejected.',
                  ),
                ),
                DropdownButtonFormField<LearningReview>(
                  key: ValueKey(
                    'decision-${record['id']}-${record['revision']}',
                  ),
                  initialValue: _decision,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: _t('覆核決定', 'Review decision'),
                  ),
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _decision = value),
                  items: [
                    for (final state in [
                      if (_nodes.isNotEmpty) LearningReview.verified,
                      LearningReview.needsInformation,
                      LearningReview.rejected,
                    ])
                      DropdownMenuItem(
                        value: state,
                        child: Text(_state(state.name)),
                      ),
                  ],
                ),
                TextField(
                  controller: _reviewer,
                  enabled: !_busy,
                  maxLength: 120,
                  decoration: InputDecoration(labelText: _t('覆核人', 'Reviewer')),
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  controller: _reason,
                  enabled: !_busy,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: _t(
                      '覆核原因（至少 5 字）',
                      'Review reason (at least 5 characters)',
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                if (_decision == LearningReview.verified) ...[
                  DropdownButtonFormField<String>(
                    initialValue: _node,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: _t('實際路標', 'Actual landmark'),
                    ),
                    items: [
                      for (final node in _nodes)
                        DropdownMenuItem(
                          value: node.id,
                          child: Text(
                            _name(node.id),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _node = value),
                  ),
                  TextField(
                    controller: _floor,
                    enabled: !_busy,
                    maxLength: 40,
                    decoration: InputDecoration(
                      labelText: _t('實際樓層', 'Actual floor'),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      _t('已在現場核對方向', 'Checked travel direction at the site'),
                    ),
                    value: _direction,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _direction = value!),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      _t(
                        '已核對出口或確認此處無出口',
                        'Checked the exit or confirmed there is no exit here',
                      ),
                    ),
                    value: _exit,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _exit = value!),
                  ),
                ],
                FilledButton(
                  onPressed: _canSave ? _update : null,
                  child: Text(_t('保存覆核', 'Save review')),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _confirmDelete,
                  child: Text(_t('刪除此候選', 'Delete this candidate')),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete() async {
    final id = _record?['id'];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('刪除此候選？', 'Delete this candidate?')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_t('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_t('刪除', 'Delete')),
          ),
        ],
      ),
    );
    if (mounted && _foreground && confirm == true && _record?['id'] == id) {
      await _update(delete: true);
    }
  }
}
