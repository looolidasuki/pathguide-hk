import 'dart:async';

import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import 'cross_floor_contract.dart';
import 'encrypted_route_store.dart';
import 'recorded_route_controller.dart';
import 'route_package.dart';

/// Product recording and replay. Merely opening the library never opens camera.
class RouteJourneyPage extends StatefulWidget {
  const RouteJourneyPage({
    super.key,
    required this.settings,
    this.initialRecording = false,
    this.createController,
    this.previewBuilder,
  });
  final AppSettings settings;
  final bool initialRecording;
  final Future<RecordedRouteController> Function()? createController;
  final WidgetBuilder? previewBuilder;
  @override
  State<RouteJourneyPage> createState() => _RouteJourneyPageState();
}

class _RouteJourneyPageState extends State<RouteJourneyPage>
    with WidgetsBindingObserver {
  RecordedRouteController? c;
  final _name = TextEditingController(), _actualFloor = TextEditingController();
  bool _loading = true,
      _loadError = false,
      _newRoute = false,
      _direction = false,
      _leaving = false;
  bool _allowPop = false;
  String? _target;
  ({
    String name,
    String floor,
    ConnectorMode mode,
    bool confirmed,
    bool floorContext,
    String? nodeId,
  })?
  _pendingLandmark;
  Timer? _expiry;
  String t(String zh, String en) =>
      widget.settings.language == AppLanguage.english ? en : zh;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _newRoute = widget.initialRecording;
    _load();
    // Fresh position evidence expires independently of button presses.
    _expiry = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && c?.mode == RecordedRouteMode.replay) setState(() {});
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = false;
    });
    try {
      final controller =
          await (widget.createController?.call() ??
              EncryptedRouteStore.open().then(
                (s) => RecordedRouteController(store: s),
              ));
      if (!mounted) {
        controller.dispose();
        return;
      }
      c = controller;
      c!.addListener(_changed);
      await c!.refresh();
    } catch (_) {
      if (mounted) _loadError = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Inactive also includes system input/permission surfaces. Native camera
    // interruption events still revoke the session; real background never resumes.
    if (state == AppLifecycleState.resumed) c?.setForeground(true);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      c?.setForeground(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _expiry?.cancel();
    c?.removeListener(_changed);
    c?.dispose();
    _name.dispose();
    _actualFloor.dispose();
    super.dispose();
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t('確認', 'Confirm')),
            ),
          ],
        ),
      ) ==
      true;
  Future<void> _back() async {
    if (_leaving) return;
    _leaving = true;
    try {
      final controller = c;
      if (controller != null) {
        await controller.pause();
        if (!mounted || controller.notice == 'stopUnconfirmed') return;
        if (controller.dirty || _pendingLandmark != null) {
          final choice = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
              scrollable: true,
              title: Text(t('離開錄路？', 'Leave recording?')),
              content: Text(
                t('未保存的路標仍在此頁。', 'There are unsaved landmarks on this page.'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'stay'),
                  child: Text(t('留在此頁', 'Stay')),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'discard'),
                  child: Text(t('捨棄並離開', 'Discard and leave')),
                ),
                FilledButton(
                  onPressed: _pendingLandmark != null
                      ? null
                      : () => Navigator.pop(ctx, 'save'),
                  child: Text(t('保存草稿並離開', 'Save draft and leave')),
                ),
              ],
            ),
          );
          if (choice == 'save') {
            await controller.save(activate: false);
            if (controller.dirty || controller.notice != 'saved') return;
          } else if (choice != 'discard') {
            return;
          }
        }
      }
      if (!mounted) return;
      if (controller != null && controller.mode != RecordedRouteMode.library) {
        await controller.showLibrary();
        if (!mounted) return;
        _pendingLandmark = null;
        _target = null;
        _actualFloor.clear();
        _direction = false;
        setState(() => _newRoute = false);
      } else if (_newRoute) {
        setState(() => _newRoute = false);
      } else {
        setState(() => _allowPop = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      }
    } finally {
      _leaving = false;
    }
  }

  Widget button(
    String zh,
    String en,
    VoidCallback? action, {
    bool primary = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: primary
        ? FilledButton(
            onPressed: action,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
            ),
            child: Text(t(zh, en)),
          )
        : OutlinedButton(
            onPressed: action,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
            ),
            child: Text(t(zh, en)),
          ),
  );
  Widget heading(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Semantics(
      header: true,
      child: Text(text, style: Theme.of(context).textTheme.titleLarge),
    ),
  );
  Widget _status() {
    final controller = c!;
    final messages = <String, (String, String)>{
      'ready': controller.mode == RecordedRouteMode.library
          ? ('選擇路線，或開始錄製新路線。', 'Choose a route or record a new one.')
          : controller.mode == RecordedRouteMode.replay
          ? ('請停下並確認身處的路標。', 'Stop and confirm the landmark where you are.')
          : controller.automaticRecording
          ? (
              '自動取樣中；重要位置可手動補記。',
              'Automatic sampling; mark important points manually.',
            )
          : ('可以記錄路標。', 'Ready to record a landmark.'),
      'paused': (
        '已暫停；按繼續才會再開相機。',
        'Paused. Resume explicitly to open the camera.',
      ),
      'captured': ('已加入路標，請保存路線。', 'Landmark added. Save your route.'),
      'edited': ('已更改，請保存路線。', 'Changes made. Save your route.'),
      'duplicate': (
        '此路標已有這張照片；請換個角度再拍。',
        'This view already exists. Try another angle.',
      ),
      'saved': ('已在此裝置加密保存。', 'Saved encrypted on this device.'),
      'draft': (
        '這是草稿；補齊樓層及路段確認後才可重行。',
        'Draft. Confirm floors and connections before replay.',
      ),
      'incompatible': (
        '這個版本無法在目前裝置重認，請重新錄製。',
        'This version cannot be matched here. Record it again.',
      ),
      'replayReady': (
        '按開始重行，再確認你身處的路標。',
        'Start replay, then confirm the landmark where you are.',
      ),
      'starting': ('正在開啟相機；可按停止取消。', 'Opening camera. Press Stop to cancel.'),
      'capturing': (
        '正在取得及分析相片；可按停止取消。',
        'Capturing and analyzing. Press Stop to cancel.',
      ),
      'stopping': ('正在停止相機，請稍候。', 'Stopping camera. Please wait.'),
      'captureFailed': (
        '未能取得或分析相片，尚未加入路標。請停止相機，再按繼續重試。',
        'Could not capture or analyze the photo. No landmark was added. Stop the camera, then resume to retry.',
      ),
      'failed': (
        '相機未有回應。請按停止，再繼續重試。',
        'Camera did not respond. Press Stop, then resume to retry.',
      ),
      'automaticLowDetail': (
        '這張畫面細節或光線不足，未加入；仍在自動取樣。',
        'This frame lacked detail or exposure. Not added; sampling continues.',
      ),
      'automaticDuplicate': (
        '畫面與已有候選相近，未重複保存。',
        'Similar to a saved candidate; not saved again.',
      ),
      'automaticFailed': (
        '自動取樣已暫停，未加入失敗畫面。可按繼續重試或結束保存已有草稿。',
        'Automatic sampling paused; failed frame was not added. Resume explicitly or finish and save the existing draft.',
      ),
      'automaticCapacity': (
        '自動取樣已達試驗上限48張；仍可手動補記重要位置，或結束保存。',
        'Automatic sampling reached the pilot limit of 48 views. Add important points manually or finish and save.',
      ),
      'floorConfirmed': (
        '已記錄樓層確認點；之後只會沿用上下文。',
        'Floor anchor recorded. Later points only inherit its context.',
      ),
      'floorUnknown': (
        '樓層未知，繼續保存未確認草稿。',
        'Floor unknown. Continue recording an unconfirmed draft.',
      ),
      'floorChanging': (
        '轉層入口已記錄；目前樓層未知，到出口再確認。',
        'Entrance recorded. Current floor unknown; confirm at the exit.',
      ),
      'floorChangingNoPhoto': (
        '入口未能拍攝；目前樓層已改未知，路段保持草稿。',
        'Entrance capture failed. Floor is unknown; connection remains draft.',
      ),
      'floorConflict': (
        '畫面出現不同樓層線索；已撤回目前樓層上下文，繼續草稿。',
        'Conflicting floor text. Current context withdrawn; draft recording continues.',
      ),
      'segmentReviewed': (
        '已記錄這一段同層及步行確認；其他未知資料仍是草稿。',
        'Same-floor walk segment reviewed. Other unknown data remains draft.',
      ),
      'checking': ('正在比對路標。', 'Matching landmark.'),
      'confirmed': (
        '路標已確認；位置證據短暫有效。',
        'Landmark confirmed. Position evidence expires shortly.',
      ),
      'arrival': (
        '已認出最後路標，請自行確認已到達。',
        'Last landmark matched. Confirm arrival yourself.',
      ),
      'transitioning': (
        '正在轉換樓層；實際樓層尚未確認。',
        'Changing floors. Actual floor is unconfirmed.',
      ),
      'finished': ('已確認到達，重行已結束。', 'Arrival confirmed. Replay ended.'),
      'stopUnconfirmed': (
        '尚未確認相機停止；請按停止重試。',
        'Camera stop is unconfirmed. Press Stop to retry.',
      ),
      'permission': (
        '請在系統設定允許相機，再按繼續。',
        'Allow camera in Settings, then resume.',
      ),
      'unsupported': (
        '此裝置未支援路標相機。',
        'Landmark camera is unsupported on this device.',
      ),
      'deleted': ('路線已刪除。', 'Route deleted.'),
      'rolledBack': ('已還原所選版本。', 'Selected version restored.'),
      'cleaned': ('已清理未使用的本機資料。', 'Unused local data cleaned.'),
      'error': (
        '未能完成；資料容量、版本衝突或讀取可能有問題。請返回路線列表重新開啟；未保存資料仍留在此頁。',
        'Could not complete. Storage, version conflict or reading may have failed. Reopen from the library; unsaved data stays on this page.',
      ),
    };
    var message =
        messages[controller.notice] ??
        (
          '未能確認位置。請停下並核對樓層、方向，再重試。',
          'Position unconfirmed. Stop, check floor and direction, then retry.',
        );
    if (['confirmed', 'arrival'].contains(controller.notice) &&
        controller.actualNodeId == null) {
      message = (
        '位置證據已過期；請重新確認路標。',
        'Position evidence expired. Confirm the landmark again.',
      );
    }
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(t(message.$1, message.$2)),
      ),
    );
  }

  Future<void> _editLandmark({int? index, bool addView = false}) async {
    if (_pendingLandmark != null) return;
    final controller = c!;
    controller.setManualEntryPending(true);
    final existing = index == null ? null : controller.nodes[index];
    final name = TextEditingController(text: existing?.nameZh ?? '');
    final floor = TextEditingController(text: existing?.floor?.label ?? '');
    var mode = index == null
        ? ConnectorMode.walk
        : controller.incomingMode(index);
    var confirmed = index != null && controller.incomingConfirmed(index);
    var submitting = false;
    String? captureWarning;
    final needsCamera = existing == null || addView;
    final dialog = DialogRoute<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          scrollable: true,
          title: Text(
            addView
                ? t('補拍同一路標', 'Add view of same landmark')
                : existing == null
                ? t('記錄路標', 'Record landmark')
                : t('修正路標', 'Edit landmark'),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (addView)
                Text(
                  t(
                    '請留在同一個實際路標，換個角度。',
                    'Stay at the same physical landmark and change angle.',
                  ),
                ),
              if (submitting) Text(t('正在準備相機…', 'Preparing camera…')),
              if (captureWarning != null) Text(captureWarning!),
              TextField(
                controller: name,
                readOnly: addView,
                maxLength: 120,
                decoration: InputDecoration(
                  labelText: t('路標名稱', 'Landmark name'),
                ),
              ),
              if (!addView) ...[
                TextField(
                  controller: floor,
                  maxLength: 40,
                  decoration: InputDecoration(
                    labelText: t('實際樓層，例如 G、3F', 'Actual floor, e.g. G, 3F'),
                  ),
                ),
                if ((index ?? controller.nodes.length) > 0)
                  DropdownButtonFormField<ConnectorMode>(
                    initialValue: mode,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: t(
                        '從上一點實際走過的路段',
                        'Connection walked from previous point',
                      ),
                    ),
                    items: [
                      for (final v in ConnectorMode.values)
                        DropdownMenuItem(value: v, child: Text(_modeName(v))),
                    ],
                    onChanged: (v) => update(() => mode = v!),
                  ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: confirmed,
                  onChanged: (v) => update(() => confirmed = v!),
                  title: Text(
                    t(
                      '我已到達並核實樓層及剛走過的路段',
                      'I have arrived and checked the floor and connection walked',
                    ),
                  ),
                ),
                Text(
                  t('未確認會保留成草稿。', 'Unconfirmed information remains a draft.'),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (submitting) unawaited(controller.pause());
                Navigator.pop(ctx, false);
              },
              child: Text(t('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: submitting
                  ? null
                  : () async {
                      if (name.text.trim().isEmpty) return;
                      FocusScope.of(ctx).unfocus();
                      update(() {
                        submitting = true;
                        captureWarning = null;
                      });
                      // This tap explicitly authorizes resuming after a native input
                      // interruption. Keep typed fields if the camera cannot resume.
                      if (needsCamera && !controller.canCapture) {
                        await controller.resume();
                      }
                      if (!ctx.mounted) return;
                      if (needsCamera && !controller.canCapture) {
                        update(() {
                          submitting = false;
                          captureWarning = t(
                            '相機未能準備好；輸入仍保留。請取消後按停止，再繼續重試。',
                            'Camera is not ready. Your input is kept. Cancel, press Stop, then resume and retry.',
                          );
                        });
                        return;
                      }
                      Navigator.pop(ctx, true);
                    },
              child: Text(
                existing == null || addView
                    ? t('拍攝並加入', 'Capture and add')
                    : t('確認更改', 'Apply changes'),
              ),
            ),
          ],
        ),
      ),
    );
    final accepted = await Navigator.of(context).push(dialog);
    final n = name.text, f = floor.text;
    // The popped Future precedes the reverse animation. Dispose only once the
    // route overlay (including focused TextFields) has actually been removed.
    unawaited(
      dialog.completed.then((_) {
        name.dispose();
        floor.dispose();
      }),
    );
    if (accepted != true && submitting) unawaited(controller.pause());
    if (accepted != true || !mounted) {
      controller.setManualEntryPending(false);
      return;
    }
    if (index != null && !addView) {
      controller.updateNode(index, n, f, mode, confirmed);
      controller.setManualEntryPending(false);
    } else {
      _pendingLandmark = (
        name: n,
        floor: f,
        mode: mode,
        confirmed: confirmed,
        floorContext: false,
        nodeId: addView ? existing!.id : null,
      );
      await _retryPendingLandmark();
    }
  }

  Future<void> _retryPendingLandmark() async {
    final pending = _pendingLandmark;
    if (pending == null || c!.busy) return;
    if (!c!.running) await c!.resume();
    if (!mounted || !c!.canCapture) return;
    final added = pending.floorContext
        ? await c!.confirmCurrentFloor(pending.floor)
        : await c!.recordLandmark(
            pending.name,
            pending.floor,
            mode: pending.mode,
            confirmed: pending.confirmed,
            nodeId: pending.nodeId,
            inheritContext: !pending.confirmed && pending.floor.trim().isEmpty,
          );
    if (mounted && added && _pendingLandmark == pending) {
      setState(() => _pendingLandmark = null);
      c!.setManualEntryPending(false);
    }
  }

  String _modeName(ConnectorMode mode) => switch (mode) {
    ConnectorMode.walk => t('步行（同層）', 'Walk (same floor)'),
    ConnectorMode.elevator => t('升降機', 'Lift'),
    ConnectorMode.stairs => t('樓梯', 'Stairs'),
    ConnectorMode.escalator => t('扶手電梯', 'Escalator'),
  };
  List<Widget> _library() => [
    Text(
      t(
        '路標照片及樓層只在此裝置加密保存。沒有已錄路線或室內地圖時，無法自動找室內目的地。',
        'Landmark photos and floors are encrypted on this device. Without a recorded route or indoor map, indoor destinations cannot be routed automatically.',
      ),
    ),
    if (c!.entries.isEmpty) heading(t('尚未有已錄路線', 'No recorded routes yet')),
    for (final entry in c!.entries)
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                entry.problem == null
                    ? entry.name
                    : t('未能核對的資料', 'Unverified data'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                entry.problem != null
                    ? t('資料未能核對，暫不可重行', 'Data unverified; replay unavailable')
                    : entry.activeVersion != null
                    ? t('已有可重行版本', 'Replay version available')
                    : t('草稿，尚未可重行', 'Draft, not ready to replay'),
              ),
              button(
                '開啟路線',
                'Open route',
                c!.busy
                    ? null
                    : () async {
                        await c!.open(entry);
                        _target = c!.nodes.firstOrNull?.id;
                        _actualFloor.clear();
                        _direction = false;
                      },
              ),
              button(
                '繼續編輯草稿',
                'Continue editing',
                c!.busy ? null : () => c!.open(entry, recording: true),
              ),
              if (entry.rollbackVersions.isNotEmpty)
                PopupMenuButton<int>(
                  tooltip: t('還原舊版本', 'Restore previous version'),
                  onSelected: (v) async {
                    if (await _confirm(
                      t('還原舊版本？', 'Restore version?'),
                      t(
                        '會改用所選版本，保留目前版本作歷史。',
                        'The selected version becomes active; the current version remains in history.',
                      ),
                    )) {
                      await c!.rollback(entry, v);
                    }
                  },
                  itemBuilder: (_) => [
                    for (final v in entry.rollbackVersions)
                      PopupMenuItem(
                        value: v,
                        child: Text('${t('版本', 'Version')} $v'),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(t('還原舊版本', 'Restore previous version')),
                  ),
                ),
              button(
                '刪除此路線',
                'Delete route',
                c!.busy
                    ? null
                    : () async {
                        if (await _confirm(
                          t('刪除此路線？', 'Delete route?'),
                          t(
                            '會刪除此裝置的路線、照片及所有版本。',
                            'Deletes this device’s route, photos and all versions.',
                          ),
                        )) {
                          await c!.delete(entry);
                        }
                      },
              ),
            ],
          ),
        ),
      ),
    button(
      '錄製新路線',
      'Record new route',
      c!.busy ? null : () => setState(() => _newRoute = true),
      primary: true,
    ),
    button('重新整理', 'Refresh', c!.busy ? null : c!.refresh),
    button(
      '清理未使用資料',
      'Clean unused data',
      c!.busy
          ? null
          : () async {
              if (await _confirm(
                t('清理歷史資料？', 'Clean history?'),
                t(
                  '會移除未使用資料及舊歷史；目前、草稿及回復版本會保留。',
                  'Removes unused data and older history; current, draft and rollback versions remain.',
                ),
              )) {
                await c!.cleanup();
              }
            },
    ),
  ];
  Future<void> _chooseRecordingFloor() async {
    if (_pendingLandmark != null || !c!.canCapture) return;
    c!.setManualEntryPending(true);
    final controller = TextEditingController();
    final suggestions = c!.floorCandidates;
    final route = DialogRoute<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t('確認目前樓層', 'Confirm current floor')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t(
                '相片文字只係候選。知道目前樓層先確認；唔肯定可繼續錄草稿。',
                'Image text is only a candidate. Confirm only if you know your floor; otherwise keep recording a draft.',
              ),
            ),
            if (suggestions.isNotEmpty)
              Text(t('剛才畫面嘅文字候選', 'Text candidates from the recent frame')),
            for (final floor in {...suggestions, 'G', '1F', '2F', '3F'})
              button(
                '確認目前係 $floor',
                'Confirm current floor $floor',
                () => Navigator.pop(ctx, floor),
              ),
            TextField(
              controller: controller,
              maxLength: 40,
              decoration: InputDecoration(
                labelText: t('其他樓層（選填）', 'Other floor (optional)'),
              ),
            ),
            button('確認輸入樓層', 'Confirm entered floor', () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(ctx, controller.text.trim());
              }
            }),
            button(
              '唔肯定，繼續未確認草稿',
              'Unknown, continue draft',
              () => Navigator.pop(ctx, ''),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t('取消', 'Cancel')),
          ),
        ],
      ),
    );
    final choice = await Navigator.of(context).push(route);
    unawaited(route.completed.then((_) => controller.dispose()));
    if (!mounted) return;
    if (choice == null || choice.isEmpty) {
      if (choice == '') c!.markFloorUnknown();
      c!.setManualEntryPending(false);
      return;
    }
    _pendingLandmark = (
      name: t('確認樓層 $choice', 'Confirm floor $choice'),
      floor: choice,
      mode: ConnectorMode.walk,
      confirmed: true,
      floorContext: true,
      nodeId: null,
    );
    await _retryPendingLandmark();
  }

  Future<void> _markFloorChange() async {
    if (_pendingLandmark != null || !c!.canCapture) return;
    c!.setManualEntryPending(true);
    final choice = await showDialog<ConnectorMode>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t('記錄轉層入口', 'Mark floor-change entrance')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t(
                '喺入口停下補拍。之後樓層會改為未知；到出口再確認。',
                'Stop at the entrance for a checkpoint. The floor becomes unknown; confirm again at the exit.',
              ),
            ),
            for (final mode in [
              ConnectorMode.elevator,
              ConnectorMode.stairs,
              ConnectorMode.escalator,
            ])
              button(
                _modeName(mode),
                _modeName(mode),
                () => Navigator.pop(ctx, mode),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t('取消', 'Cancel')),
          ),
        ],
      ),
    );
    if (mounted && choice != null) await c!.beginFloorChange(choice);
    if (mounted) c!.setManualEntryPending(false);
  }

  String _evidenceName(FloorEvidence evidence) => switch (evidence) {
    FloorEvidence.unknown => t('未知', 'Unknown'),
    FloorEvidence.confirmed => t('此點已確認', 'Confirmed at this point'),
    FloorEvidence.inherited => t(
      '沿用上下文，未逐點核實',
      'Inherited context, not individually verified',
    ),
    FloorEvidence.segmentConfirmed => t(
      '已核實整段同層',
      'Same-floor segment reviewed',
    ),
  };

  Future<void> _finishAutomaticDraft() async {
    await c!.pause();
    if (!mounted || c!.notice == 'stopUnconfirmed') return;
    _name.text = c!.name;
    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t('結束並保存草稿', 'Finish and save draft')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t(
                '未知樓層及未確認路段保留草稿，尚未可重行。',
                'Unknown floors and unconfirmed connections remain a draft, unavailable for replay.',
              ),
            ),
            TextField(
              controller: _name,
              maxLength: 120,
              decoration: InputDecoration(labelText: t('整條路線名稱', 'Route name')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('稍後保存', 'Save later')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('保存草稿', 'Save draft')),
          ),
        ],
      ),
    );
    if (save == true && mounted) {
      await c!.save(activate: false, name: _name.text);
    }
  }

  List<Widget> _record() => [
    Text(
      t(
        c!.automaticRecording
            ? '自動錄路中，唔使逐張拍照。未知資料保留草稿；重要轉角或轉層請停下補記。'
            : '到達每個路標後停下拍攝。此版本記錄實際走過的順序，不記錄 GPS 軌跡；未提供即時避障或連續轉向語音。',
        c!.automaticRecording
            ? 'Recording automatically. Unconfirmed data stays in a draft. Stop to mark important corners or floor changes.'
            : 'Stop at each landmark to capture it. This version records the order you walked, not a GPS track. Live obstacle avoidance and continuous spoken turns are not connected.',
      ),
    ),
    heading(c!.name),
    heading(t('樓層紀錄', 'Recording floor')),
    Text(
      t(
        '之後路標會沿用本段樓層，唔代表每點已核實。轉層請記錄入口及出口。',
        'Context is for recording continuity, not a verified location at every point. Mark floor-change entrances and exits.',
      ),
    ),
    Text(
      '${t('本段樓層', 'Floor for this segment')}: ${c!.recordingFloor?.label ?? t('未知', 'Unknown')}',
    ),
    button(
      c!.recordingConnector != null ? '確認出口樓層' : '確認／更新目前樓層',
      c!.recordingConnector != null
          ? 'Confirm exit floor'
          : 'Confirm or update current floor',
      c!.canCapture && _pendingLandmark == null ? _chooseRecordingFloor : null,
    ),
    button(
      '記錄轉層入口',
      'Mark floor-change entrance',
      c!.canCapture && _pendingLandmark == null ? _markFloorChange : null,
    ),
    button(
      '樓層唔肯定，繼續草稿',
      'Floor unknown, continue draft',
      c!.canEdit && _pendingLandmark == null ? c!.markFloorUnknown : null,
    ),
    if (!c!.running)
      for (final anchor in c!.floorAnchors.where(
        (a) => c!.nodes.any((n) => n.floorAnchorId == a.id),
      ))
        button(
          '核實由 ${anchor.nameZh} 起嘅同層一段',
          'Review same-floor segment from ${anchor.nameEn}',
          c!.canEdit
              ? () async {
                  if (await _confirm(
                        t('核實這一段？', 'Review this segment?'),
                        t(
                          '我確認這一段全部在 ${anchor.floor!.label}，並按錄製方向實際走過。這不會確認其他樓層或轉層設備。',
                          'I confirm this segment stayed on ${anchor.floor!.label} and I walked it in the recorded direction. Other floors and connectors remain unconfirmed.',
                        ),
                      ) &&
                      mounted) {
                    c!.confirmFloorSegment(anchor.id);
                  }
                }
              : null,
        ),

    if (_pendingLandmark != null) ...[
      Text(
        t('相片尚未加入，已保留輸入：', 'Photo not added. Input kept: ') +
            _pendingLandmark!.name,
      ),
      button(
        '重試剛才路標',
        'Retry pending landmark',
        c!.busy ? null : _retryPendingLandmark,
        primary: true,
      ),
      button(
        '捨棄這次輸入',
        'Discard pending input',
        c!.busy
            ? null
            : () async {
                if (await _confirm(
                      t('捨棄這次輸入？', 'Discard pending input?'),
                      t(
                        '只會捨棄尚未加入的路標輸入。',
                        'Only the pending landmark input will be discarded.',
                      ),
                    ) &&
                    mounted) {
                  setState(() => _pendingLandmark = null);
                  c!.setManualEntryPending(false);
                }
              },
      ),
    ],
    Text(
      '${c!.nodes.length} ${t('個路標', 'landmarks')} · ${c!.document?.complete == true ? t('資料已齊，可保存重行版本', 'Ready to save for replay') : t('尚有資料未確認，只能保存草稿', 'Incomplete confirmations; draft only')}',
    ),
    for (var i = 0; i < c!.nodes.length; i++)
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${i + 1}. ${c!.nodes[i].nameZh} · ${c!.nodes[i].floor?.label ?? t('樓層未確認', 'Floor unknown')} · ${_evidenceName(c!.nodes[i].floorEvidence)}',
              ),
              if (i > 0)
                Text(
                  '${_modeName(c!.incomingMode(i))} · ${c!.incomingConfirmed(i) ? t('已確認', 'Confirmed') : t('路段未確認', 'Connection unconfirmed')}',
                ),
              button(
                '修正名稱／樓層／路段',
                'Edit landmark',
                c!.canEdit ? () => _editLandmark(index: i) : null,
              ),
              button(
                '補拍同一路標',
                'Add another view',
                c!.canCapture && c!.viewsFor(c!.nodes[i].id) < 4
                    ? () => _editLandmark(index: i, addView: true)
                    : null,
              ),
            ],
          ),
        ),
      ),
    button(
      c!.automaticRecording ? '手動補記重要位置' : '記錄下一個路標',
      c!.automaticRecording
          ? 'Mark important point manually'
          : 'Record next landmark',
      c!.canCapture ? () => _editLandmark() : null,
      primary: true,
    ),
    button(
      '保存草稿',
      'Save draft',
      c!.canEdit && c!.nodes.isNotEmpty ? () => c!.save(activate: false) : null,
    ),
    button(
      '完成並保存重行版本',
      'Finish and save for replay',
      c!.canEdit && c!.document?.complete == true
          ? () => c!.save(activate: true)
          : null,
      primary: true,
    ),
  ];
  List<Widget> _replay() {
    final controller = c!, exit = c!.transitionExit;
    final target =
        exit?.id ??
        (_target != null && controller.nodes.any((n) => n.id == _target)
            ? _target
            : controller.nodes.firstOrNull?.id);
    return [
      heading(controller.name),
      Text(
        t(
          '只沿錄製方向逐點重認；回程須另錄。此版本沒有即時避障或連續語音帶路。',
          'Match landmarks in the recorded direction. Record return journeys separately. Live obstacle avoidance and continuous spoken guidance are not connected.',
        ),
      ),
      Text(
        '${t('實際樓層', 'Actual floor')}: ${controller.actualFloor?.label ?? t('未確認', 'Unknown')}',
      ),
      if (controller.expectedFloor != null)
        Text(
          '${t('預期出口樓層', 'Expected exit floor')}: ${controller.expectedFloor!.label}',
        ),
      if (controller.nextPoint != null)
        Text(
          '${t('記錄的下一路標', 'Recorded next landmark')}: ${controller.nextPoint!.nameZh}',
        ),
      if (controller.replayAvailable && !controller.finished) ...[
        DropdownButtonFormField<String>(
          key: ValueKey('target-$target'),
          initialValue: target,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: t(
              '我身處的路標（可由中途恢復）',
              'Landmark where I am (mid-route recovery allowed)',
            ),
          ),
          items: [
            for (final n in controller.nodes)
              DropdownMenuItem(value: n.id, child: Text(n.nameZh)),
          ],
          onChanged: exit != null || controller.busy
              ? null
              : (v) => setState(() {
                  _target = v;
                  _actualFloor.clear();
                  _direction = false;
                }),
        ),
        TextField(
          controller: _actualFloor,
          enabled: !controller.busy,
          decoration: InputDecoration(
            labelText: t('請自行核實並輸入實際樓層', 'Check and enter your actual floor'),
          ),
          maxLength: 40,
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _direction,
          onChanged: controller.busy
              ? null
              : (v) => setState(() => _direction = v!),
          title: Text(
            t(
              '我已停下，核對出口及面向錄製的行進方向',
              'I stopped, checked the exit and face the recorded travel direction',
            ),
          ),
        ),
        button(
          '拍攝並確認此路標',
          'Capture and confirm landmark',
          controller.canCheck && target != null
              ? () async {
                  await controller.checkPosition(
                    target,
                    _actualFloor.text,
                    directionConfirmed: _direction,
                  );
                  if (mounted) {
                    setState(() {
                      _actualFloor.clear();
                      _direction = false;
                    });
                  }
                }
              : null,
          primary: true,
        ),
        if (controller.nextConnector != null &&
            controller.nextConnector != ConnectorMode.walk &&
            exit == null)
          button(
            '開始轉換樓層',
            'Begin floor transition',
            controller.actualNodeId != null
                ? () {
                    if (controller.enterConnector()) {
                      _actualFloor.clear();
                      _direction = false;
                    }
                  }
                : null,
          ),
        button(
          '我已到達，結束重行',
          'Confirm arrival and finish',
          controller.atArrival && !controller.busy
              ? controller.confirmArrival
              : null,
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: _back,
          tooltip: t('返回', 'Back'),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(t('我的路線', 'My routes')),
      ),
      bottomNavigationBar: c != null && c!.mode != RecordedRouteMode.library
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (c!.mode == RecordedRouteMode.record &&
                        c!.automaticRecording)
                      button(
                        '結束錄路並命名保存',
                        'Finish, name and save',
                        c!.busy || c!.nodes.isEmpty
                            ? null
                            : _finishAutomaticDraft,
                        primary: true,
                      ),
                    if (!c!.running &&
                        c!.notice != 'stopUnconfirmed' &&
                        !c!.finished &&
                        (c!.mode == RecordedRouteMode.record ||
                            c!.replayAvailable))
                      button(
                        c!.mode == RecordedRouteMode.record ? '繼續錄路' : '開始重行',
                        c!.mode == RecordedRouteMode.record
                            ? 'Resume recording'
                            : 'Start replay',
                        c!.busy ? null : c!.resume,
                        primary: true,
                      ),
                    button(
                      c!.running ? '暫停' : '停止',
                      c!.running ? 'Pause' : 'Stop',
                      c!.pause,
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: SafeArea(
        child: _loading
            ? Center(child: Text(t('讀取路線中', 'Loading routes')))
            : _loadError
            ? ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    t(
                      '未能開啟本機路線，請解鎖裝置再試。',
                      'Cannot open local routes. Unlock the device and retry.',
                    ),
                  ),
                  button('重試', 'Retry', _load),
                ],
              )
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _status(),
                  // Keep sibling positions stable while capture changes busy.
                  SizedBox(
                    height: 4,
                    child: c!.busy ? const LinearProgressIndicator() : null,
                  ),
                  if (c!.mode != RecordedRouteMode.library)
                    _RetainedRoutePreview(
                      key: const ValueKey('recorded-route-camera-preview'),
                      visible: c!.running,
                      child:
                          widget.previewBuilder?.call(context) ??
                          const UiKitView(
                            viewType: 'hk.pathguide/route_camera/preview',
                          ),
                    ),
                  if (c!.mode == RecordedRouteMode.library && _newRoute) ...[
                    heading(t('錄製新路線', 'Record new route')),
                    Text(
                      t(
                        '即使第一次行這條路亦可錄製。按開始才開相機；拍下的路標照片會隨路線保存在此裝置。請在安全位置停下操作。',
                        'You can record an unfamiliar route. The camera opens only after Start. Captured landmark photos are saved with the route on this device. Stop somewhere safe to operate.',
                      ),
                    ),
                    TextField(
                      controller: _name,
                      maxLength: 120,
                      decoration: InputDecoration(
                        labelText: t(
                          '路線名稱（可在結束後填寫）',
                          'Route name (can be named at the end)',
                        ),
                      ),
                    ),
                    button(
                      '開始錄路',
                      'Start recording',
                      c!.busy
                          ? null
                          : () => c!.startRecording(
                              _name.text.trim().isEmpty
                                  ? t('未命名路線', 'Untitled route')
                                  : _name.text,
                              automatic: true,
                            ),
                      primary: true,
                    ),
                  ] else if (c!.mode == RecordedRouteMode.library)
                    ..._library()
                  else if (c!.mode == RecordedRouteMode.record)
                    ..._record()
                  else
                    ..._replay(),
                ],
              ),
      ),
    ),
  );
}

/// Keep the native layer through busy, pause and list scrolling. Native owns
/// session attachment and detaches before physical stop; UI disposal cannot race it.
class _RetainedRoutePreview extends StatefulWidget {
  const _RetainedRoutePreview({
    super.key,
    required this.visible,
    required this.child,
  });
  final bool visible;
  final Widget child;
  @override
  State<_RetainedRoutePreview> createState() => _RetainedRoutePreviewState();
}

class _RetainedRoutePreviewState extends State<_RetainedRoutePreview>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Visibility(
      visible: widget.visible,
      maintainState: true,
      child: SizedBox(height: 180, child: widget.child),
    );
  }
}
