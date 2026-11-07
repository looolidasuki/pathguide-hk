import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import 'route_library_controller.dart';
import 'route_package.dart';

class RouteLibraryPage extends StatefulWidget {
  const RouteLibraryPage({
    super.key,
    required this.controller,
    required this.settings,
    required this.onBack,
  });
  final RouteLibraryController controller;
  final AppSettings settings;
  final VoidCallback onBack;
  @override
  State<RouteLibraryPage> createState() => _RouteLibraryPageState();
}

class _RouteLibraryPageState extends State<RouteLibraryPage>
    with WidgetsBindingObserver {
  late final TextEditingController _name = TextEditingController(
    text: _defaultName,
  );
  int _dialogEpoch = 0;
  bool _seeded = false;

  String get _defaultName => widget.settings.language == AppLanguage.english
      ? 'Sample cross-floor'
      : '樣例跨樓層';
  bool get _en => widget.settings.language == AppLanguage.english;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onControllerChanged);
    if (!_seeded) {
      _seeded = true;
      _name.text = _defaultName;
    }
    widget.controller.refresh();
  }

  void _onControllerChanged() {
    _dialogEpoch++;
  }

  @override
  void didUpdateWidget(covariant RouteLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _dialogEpoch++;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.controller.setForeground(true);
    } else {
      widget.controller.setForeground(false);
    }
    _dialogEpoch++;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onControllerChanged);
    widget.controller.pause();
    _name.dispose();
    super.dispose();
  }

  String _t(String zh, String en) => _en ? en : zh;

  String _problem(RouteProblem p) => switch (p) {
    RouteProblem.invalid => _t('輸入或內容無效。', 'Invalid input or content.'),
    RouteProblem.conflict => _t(
      '資料已變更，請先重新載入再重試。',
      'Data changed; reload before retry.',
    ),
    RouteProblem.cancelled => _t('操作已取消。', 'Operation cancelled.'),
    RouteProblem.deleted => _t('項目已刪除。', 'Item deleted.'),
    RouteProblem.notFound => _t('找不到該項目。', 'Item not found.'),
    RouteProblem.corrupt => _t(
      '內容無法讀取，資料已保留。',
      'Content unreadable; data retained.',
    ),
    RouteProblem.incompatible => _t('版本不相容。', 'Incompatible format.'),
    RouteProblem.keyUnavailable => _t(
      '本機金鑰無法使用，資料已保留。',
      'Local key unavailable; data retained.',
    ),
    RouteProblem.busy => _t('忙碌中，請稍候。', 'Busy; try again.'),
    RouteProblem.io => _t(
      '無法確認操作結果，請重新載入。',
      'Cannot confirm operation; reload.',
    ),
    RouteProblem.cleanupPending => _t(
      '已標記刪除，檔案清理待完成。',
      'Logically deleted; file cleanup pending.',
    ),
    RouteProblem.capacity => _t(
      '版本或儲存空間已滿，請執行清理。',
      'Version/storage limit reached; run cleanup.',
    ),
    RouteProblem.outcomeUnknown => _t(
      '結果未確認，請重新載入，不會自動重送。',
      'Outcome not confirmed; reload. No automatic resend.',
    ),
  };

  String _notice(LibraryNotice n) => switch (n) {
    LibraryNotice.ready => '',
    LibraryNotice.saved => _t('已儲存。', 'Saved.'),
    LibraryNotice.rolledBack => _t('已回滾。', 'Rolled back.'),
    LibraryNotice.deleted => _t('已刪除。', 'Deleted.'),
    LibraryNotice.cleaned => _t('已清理。', 'Cleaned up.'),
    LibraryNotice.paused => _t('已暫停。', 'Paused.'),
  };

  Future<bool> _confirm({
    required String body,
    required String confirmKey,
  }) async {
    final c = widget.controller;
    final epoch = _dialogEpoch;
    final gen = c.generation;
    FocusScope.of(context).unfocus();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(_t('取消', 'Cancel')),
          ),
          FilledButton(
            key: Key(confirmKey),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(_t('確認', 'Confirm')),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    if (result != true) return false;
    if (!identical(widget.controller, c)) return false;
    if (_dialogEpoch != epoch || c.generation != gen) return false;
    if (!c.foreground || !c.canAct) return false;
    return true;
  }

  Future<void> _cleanup() async {
    final c = widget.controller;
    final ok = await _confirm(
      confirmKey: 'library-confirm-cleanup',
      body: _t(
        '清理將保留使用中的版本、最新已驗證的可回滾版本與目前草稿；'
            '移除較舊的歷史與未被引用的暫存檔。',
        'Cleanup keeps the active version, the latest verified rollback '
            'and the current draft; older history and unreferenced temp '
            'files are removed.',
      ),
    );
    if (!ok) return;
    c.cleanup();
  }

  Future<void> _delete(RouteLibraryEntry entry) async {
    final c = widget.controller;
    final ok = await _confirm(
      confirmKey: 'library-confirm-delete',
      body: _t(
        '刪除「${entry.name}」？此操作無法復原。',
        'Delete "${entry.name}"? This cannot be undone.',
      ),
    );
    if (!ok) return;
    c.delete(entry);
  }

  Widget _btn(String labelZh, String labelEn, Key key, VoidCallback? onTap) =>
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            key: key,
            onPressed: onTap,
            child: Text(
              _en ? labelEn : labelZh,
              textAlign: TextAlign.center,
              softWrap: true,
            ),
          ),
        ),
      );

  Widget _panel(ColorScheme s, Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: s.secondaryContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: DefaultTextStyle.merge(
      style: TextStyle(color: s.onSecondaryContainer),
      child: child,
    ),
  );

  Widget _entryTile(RouteLibraryEntry e, ColorScheme s) {
    final c = widget.controller;
    final canRev = c.canAct && e.problem == null;
    final name = e.name.trim().isEmpty
        ? _t('（無法讀取的名稱）', '(unreadable sample)')
        : e.name;
    return Container(
      key: ValueKey('library-row-${e.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: s.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            _t(
              '使用中版本：${e.activeVersion ?? '無'}　草稿版本：${e.draftVersion ?? '無'}',
              'Active: ${e.activeVersion ?? 'none'}  Draft: ${e.draftVersion ?? 'none'}',
            ),
          ),
          Text(
            _t(
              '歷史版本：${e.versions.isEmpty ? '無' : e.versions.join('、')}',
              'History: ${e.versions.isEmpty ? 'none' : e.versions.join(', ')}',
            ),
          ),
          if (e.problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _problem(e.problem!),
                style: TextStyle(color: s.error),
              ),
            ),
          const SizedBox(height: 8),
          _btn(
            '儲存完整樣例修訂',
            'Save complete sample revision',
            Key('library-version-${e.id}'),
            canRev ? () => c.saveRevision(e, draft: false) : null,
          ),
          const SizedBox(height: 8),
          _btn(
            '儲存草稿修訂',
            'Save draft revision',
            Key('library-draft-${e.id}'),
            canRev ? () => c.saveRevision(e, draft: true) : null,
          ),
          for (final v in e.rollbackVersions) ...[
            const SizedBox(height: 8),
            _btn(
              '回滾至版本 $v',
              'Roll back to version $v',
              Key('library-rollback-${e.id}-$v'),
              c.canAct ? () => c.rollback(e, v) : null,
            ),
          ],
          const SizedBox(height: 8),
          _btn(
            '刪除此樣例',
            'Delete this sample',
            Key('library-delete-${e.id}'),
            c.canAct ? () => _delete(e) : null,
          ),
        ],
      ),
    );
  }

  Widget _body(ColorScheme s) {
    final c = widget.controller;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _panel(
          s,
          Text(
            _t(
              '此頁僅含本機樣例路線，存於本機。不含照片、影片、上傳或即時導航；'
                  '實際錄製尚未接上。結構完整並不代表可即時導航。',
              'This page contains local sample routes only, stored on this '
                  'device. No photos, video, upload or live navigation; actual '
                  'recording is not connected. Structural completeness does '
                  'not mean live-navigation ready.',
            ),
          ),
        ),
        const SizedBox(height: 12),
        _panel(s, Text(_t('來源一律為合成資料。', 'Source is always synthetic.'))),
        const SizedBox(height: 12),
        if (c.error != null)
          _panel(s, Text(_problem(c.error!), style: TextStyle(color: s.error))),
        if (c.error != null) const SizedBox(height: 12),
        if (c.notice != LibraryNotice.ready && c.error == null)
          _panel(s, Text(_notice(c.notice))),
        if (c.notice != LibraryNotice.ready && c.error == null)
          const SizedBox(height: 12),
        if (c.paused && c.error != null) ...[
          _panel(s, Text(_t('已暫停。', 'Paused.'))),
          const SizedBox(height: 12),
        ],
        if (c.pendingCleanup > 0) ...[
          _panel(
            s,
            Text(
              _t(
                '待清理項目：${c.pendingCleanup}',
                'Pending cleanup: ${c.pendingCleanup}',
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          key: const ValueKey('library-name'),
          controller: _name,
          maxLength: 120,
          enabled: c.canAct,
          decoration: InputDecoration(
            labelText: _t('樣例名稱', 'Sample name'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        _btn(
          '儲存草稿',
          'Save draft',
          const Key('library-save-draft'),
          c.canAct ? () => c.addSample(_name.text, draft: true) : null,
        ),
        const SizedBox(height: 8),
        _btn(
          '儲存完整樣例',
          'Save complete sample',
          const Key('library-save-complete'),
          c.canAct ? () => c.addSample(_name.text, draft: false) : null,
        ),
        const SizedBox(height: 8),
        _btn(
          '重新載入（會恢復）',
          'Refresh (resumes)',
          const Key('library-refresh'),
          (!c.busy && c.foreground) ? () => c.refresh() : null,
        ),
        const SizedBox(height: 8),
        _btn(
          '清理舊版本與暫存',
          'Clean up old versions & temp',
          const Key('library-cleanup'),
          c.canAct ? _cleanup : null,
        ),
        const SizedBox(height: 16),
        if (c.busy)
          _panel(s, Text(_t('處理中…', 'Working…')))
        else if (c.entries.isEmpty)
          _panel(s, Text(_t('尚無樣例。', 'No samples yet.')))
        else
          for (final e in c.entries) _entryTile(e, s),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return SafeArea(
      child: AnimatedBuilder(
        animation: Listenable.merge([widget.controller, widget.settings]),
        builder: (context, _) {
          final c = widget.controller;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: s.secondary,
                child: Text(
                  _t('本機路線庫（樣例）', 'Local route library (samples)'),
                  textAlign: TextAlign.center,
                  softWrap: true,
                  style: TextStyle(
                    color: s.onSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(child: _body(s)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: _btn('返回', 'Back', const Key('library-back'), () {
                        c.pause();
                        widget.onBack();
                      }),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _btn(
                        '暫停',
                        'Pause',
                        const Key('library-pause'),
                        c.paused ? null : c.pause,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
