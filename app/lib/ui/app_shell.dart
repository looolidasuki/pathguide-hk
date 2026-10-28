import '../l10n/app_language.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../settings/app_settings.dart';
import '../vision/model_manifest.dart';
import '../vision/platform_vision.dart' show defaultModelManifestKey;
import 'app_theme.dart';
import 'demo_page.dart';
import 'task_home_page.dart';
import 'usage_guide.dart';
import '../account/account_ui.dart';
import '../menu/menu_page.dart';
import '../navigation/navigation_page.dart';
import '../indoor/graph_replay_page.dart';
import '../depth/depth_page.dart';

enum AppSection { home, explore, navigation, settings }

/// Main product shell. Camera resources only exist while Explore is visible.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    this.initialSection = AppSection.home,
    this.initialVisionMode = SourceMode.camera,
    required this.settings,
  });

  final AppSection initialSection;
  final SourceMode initialVisionMode;
  final AppSettings settings;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late AppSection _section = widget.initialSection;

  bool _accountVisible = false;
  bool _menuVisible = false;
  bool _graphVisible = false;
  bool _depthVisible = false;
  bool _navigationTask = false, _confirmingNavigationExit = false;
  Future<void> _select(AppSection section) async {
    if (_section == section &&
        !_accountVisible &&
        !_menuVisible &&
        !_graphVisible &&
        !_depthVisible) {
      return;
    }
    if (_section == AppSection.navigation &&
        _navigationTask &&
        section != _section) {
      if (_confirmingNavigationExit) return;
      setState(() => _confirmingNavigationExit = true);
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const AppText('結束導航並離開？'),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const AppText('繼續導航'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const AppText('確認結束'),
            ),
          ],
        ),
      );
      if (mounted) setState(() => _confirmingNavigationExit = false);
      if (leave != true || !mounted) return;
    }
    _navigationTask = false;
    setState(() {
      _section = section;
      _accountVisible = false;
      _menuVisible = false;
      _graphVisible = false;
      _depthVisible = false;
    });
  }

  void _openAccount() => setState(() => _accountVisible = true);

  Widget _page() => switch (_section) {
    AppSection.home => TaskHomePage(
      onExplore: () => _select(AppSection.explore),
      onNavigation: () => _select(AppSection.navigation),
      onSettings: () => _select(AppSection.settings),
      onAccount: _openAccount,
      onMenu: () => setState(() => _menuVisible = true),
    ),
    AppSection.explore => DemoPage(
      initialMode: widget.initialVisionMode,
      settings: widget.settings,
      onBack: () => _select(AppSection.home),
      onAccount: _openAccount,
    ),
    AppSection.navigation => NavigationPage(
      settings: widget.settings,
      onTaskChanged: (active) => _navigationTask = active,
      speechSuspended: _confirmingNavigationExit,
      onOpenReplay: () => setState(() => _graphVisible = true),
      onOpenDepth: () => setState(() => _depthVisible = true),
    ),
    AppSection.settings => SettingsPage(
      onAccount: _openAccount,
      onOpenExplore: () => _select(AppSection.explore),
      settings: widget.settings,
    ),
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Dispose the outgoing camera immediately. An AnimatedSwitcher would
      // keep it alive (and potentially speaking) during its exit animation.
      body: KeyedSubtree(
        key: ValueKey(
          _depthVisible
              ? 'depth'
              : _graphVisible
              ? 'graph-replay'
              : _menuVisible
              ? 'menu'
              : _accountVisible
              ? 'account'
              : _section,
        ),
        child: _depthVisible
            ? DepthPage(
                settings: widget.settings,
                onBack: () => setState(() => _depthVisible = false),
              )
            : _graphVisible
            ? GraphReplayPage(
                settings: widget.settings,
                onBack: () => setState(() => _graphVisible = false),
              )
            : _menuVisible
            ? MenuPage(
                settings: widget.settings,
                onBack: () => setState(() => _menuVisible = false),
              )
            : _accountVisible
            ? AccountPage(onBack: () => setState(() => _accountVisible = false))
            : _page(),
      ),
      bottomNavigationBar: _AppNavigationBar(
        selected: _section,
        onSelected: _select,
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    this.onAccount,
    super.key,
    required this.onOpenExplore,
    required this.settings,
  });

  final VoidCallback onOpenExplore;
  final AppSettings settings;
  final VoidCallback? onAccount;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppSettings get settings => widget.settings;
  VoidCallback get onOpenExplore => widget.onOpenExplore;
  late final Future<ManifestParseResult> _manifest;

  @override
  void initState() {
    super.initState();
    _manifest = rootBundle
        .loadString(defaultModelManifestKey, cache: false)
        .then(parseModelManifest)
        .catchError((Object error) => ManifestParseResult.fail('$error'));
  }

  Future<void> _showSpeechSpeedPicker(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: AnimatedBuilder(
            animation: settings,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  AppText(
                    '播報速度',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  AppText(
                    '只會調整粵語播報的速度；不會改變音量或音調。',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  for (final speed in SpeechSpeed.values)
                    _SpeechSpeedChoice(
                      speed: speed,
                      selected: settings.speechSpeed == speed,
                      onTap: () async {
                        await settings.setSpeechSpeed(speed);
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                      },
                    ),
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const AppText('關閉'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showFutureInfo(
    BuildContext context, {
    required String title,
    required String description,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 6, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const _DevelopmentBadge(),
              const SizedBox(height: 14),
              AppText(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              AppText(
                description,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(height: 18),
              AppText(
                '此版本不會要求新的系統權限，也不會開始下載或連接網絡服務。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                child: const AppText('知道了'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: AnimatedBuilder(
        animation: settings,
        builder: (context, _) => ListView(
          key: const ValueKey('settings-page'),
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
          children: <Widget>[
            Row(
              children: [
                Expanded(
                  child: AppText(
                    '設定',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
                PopupMenuButton<AppLanguage>(
                  key: const ValueKey('app-language'),
                  tooltip: context.tr('語言 / Language'),
                  icon: const Icon(Icons.language),
                  initialValue: settings.language,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: AppLanguage.chinese,
                      child: Text('繁體中文（香港）'),
                    ),
                    PopupMenuItem(
                      value: AppLanguage.english,
                      child: Text('English'),
                    ),
                  ],
                  onSelected: settings.setLanguage,
                ),
              ],
            ),
            const SizedBox(height: 6),
            AppText(
              '管理播報及即時辨識功能。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (widget.onAccount != null) ...[
              const SizedBox(height: 16),
              AccountEntry(onManage: widget.onAccount!),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => showUsageGuide(context),
              icon: const Icon(Icons.help_outline),
              label: const AppText('使用教學'),
            ),
            const SizedBox(height: 24),
            _NativeSettingsSection(
              title: '語音及即時辨識',
              children: <Widget>[
                _NativeSettingsRow(
                  key: const ValueKey<String>('speech-speed-row'),
                  icon: Icons.volume_up_rounded,
                  title: '播報速度',
                  value: settings.speechSpeed.label,
                  semanticLabel: '播報速度，目前為 ${settings.speechSpeed.label}',
                  onTap: () => _showSpeechSpeedPicker(context),
                ),
                _NativeSettingsRow(
                  icon: Icons.visibility_rounded,
                  title: '即時辨識設定',
                  value: '探索頁',
                  semanticLabel: '即時辨識設定，前往探索頁調整',
                  onTap: onOpenExplore,
                ),
              ],
            ),
            const SizedBox(height: 24),
            _NativeSettingsSection(
              title: '未來功能',
              children: <Widget>[
                _futureRow(
                  context,
                  title: '懸空障礙物偵測',
                  description: '需要可靠的深度距離資料，才可分辨頭部高度的障礙物。',
                  icon: Icons.height_rounded,
                ),
                _futureRow(
                  context,
                  title: '碰撞預警',
                  description: '需要距離感測與行進風險判斷，現有物件框不足以安全預警。',
                  icon: Icons.warning_amber_rounded,
                ),
                _futureRow(
                  context,
                  title: '場景描述分析',
                  description: '需要另一個專用的場景描述模型；本 App 目前只提供物件辨識。',
                  icon: Icons.auto_awesome_rounded,
                ),
                _futureRow(
                  context,
                  title: '導航地圖',
                  description: '戶外步行導航已接入；室內 graph 定位及路線仍待驗證。',
                  icon: Icons.map_rounded,
                ),
                _futureRow(
                  context,
                  title: '方向表達',
                  description: '需要可靠的裝置方向與指南針資料，才能提供安全的鐘點方向提示。',
                  icon: Icons.explore_rounded,
                ),
                _futureRow(
                  context,
                  title: '相機偏離暫停偵測',
                  description: '需要裝置姿態資料及經過驗證的暫停規則，目前尚未實作。',
                  icon: Icons.screen_rotation_alt_rounded,
                ),
              ],
            ),
            const SizedBox(height: 24),
            _NativeSettingsSection(
              title: '模型與下載',
              children: <Widget>[
                FutureBuilder<ManifestParseResult>(
                  future: _manifest,
                  builder: (context, snapshot) {
                    final manifest = snapshot.data?.manifest;
                    final size = manifest?.bytes;
                    final value = manifest == null
                        ? (snapshot.connectionState == ConnectionState.done
                              ? '清單暫時不可用'
                              : '正在讀取清單')
                        : '${manifest.modelClassCount} 類'
                              '${size == null ? '' : ' · ${(size / 1000000).toStringAsFixed(2)} MB'}';
                    return _NativeSettingsRow(
                      icon: Icons.memory_rounded,
                      title: '即時物件辨識模型',
                      value: value,
                      detail: manifest == null
                          ? null
                          : '版本 ${manifest.version}',
                      semanticLabel:
                          '即時物件辨識模型，$value'
                          '${manifest == null ? '' : '，版本 ${manifest.version}'}',
                    );
                  },
                ),
                _NativeSettingsRow(
                  icon: Icons.auto_awesome_outlined,
                  title: '場景描述模型',
                  value: '未提供',
                  semanticLabel: '場景描述模型，未提供，開發中',
                  onTap: () => _showFutureInfo(
                    context,
                    title: '場景描述模型',
                    description: '目前沒有可下載的場景描述模型，也不會顯示虛構的檔案大小或下載按鈕。',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const _NativeSettingsSection(
              title: '私隱',
              children: <Widget>[
                _NativeSettingsRow(
                  icon: Icons.shield_outlined,
                  title: '私隱保障',
                  value: '辨識在裝置處理',
                  semanticLabel: '私隱保障，相機畫面在裝置處理；登入與聯絡資料由 Firebase 保存',
                  detail: '基本辨識不儲存或上傳畫面。個人模型照片須另行配置及同意；聯絡資料不加入訓練。',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _futureRow(
    BuildContext context, {
    required String title,
    required String description,
    required IconData icon,
  }) {
    return _NativeSettingsRow(
      icon: icon,
      title: title,
      value: '開發中',
      semanticLabel: '$title，開發中',
      onTap: () =>
          _showFutureInfo(context, title: title, description: description),
    );
  }
}

class _SpeechSpeedChoice extends StatelessWidget {
  const _SpeechSpeedChoice({
    required this.speed,
    required this.selected,
    required this.onTap,
  });

  final SpeechSpeed speed;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '播報速度 ${speed.label}${selected ? '，已選取' : ''}',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected
            ? AppColors.primary.withValues(alpha: 0.13)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: AppText(
                      speed.label,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (selected)
                    const Icon(
                      Icons.check_rounded,
                      color: AppColors.primary,
                      semanticLabel: '已選取',
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NativeSettingsSection extends StatelessWidget {
  const _NativeSettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: AppText(
            title,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(18),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: <Widget>[
              for (var index = 0; index < children.length; index++) ...<Widget>[
                if (index > 0)
                  const Padding(
                    padding: EdgeInsets.only(left: 49),
                    child: Divider(height: 1, color: AppColors.border),
                  ),
                children[index],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _NativeSettingsRow extends StatelessWidget {
  const _NativeSettingsRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.semanticLabel,
    this.detail,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final String semanticLabel;
  final String? detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final interactive = onTap != null;
    return Semantics(
      button: interactive,
      label: context.tr(semanticLabel),
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 60),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Icon(icon, color: AppColors.primary, size: 21),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 5,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        AppText(
                          title,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (detail != null) ...<Widget>[
                          const SizedBox(height: 3),
                          AppText(
                            detail!,
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    flex: 4,
                    child: AppText(
                      value,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                        color: value == '開發中'
                            ? AppColors.warning
                            : AppColors.textMuted,
                        fontSize: 15,
                        height: 1.2,
                      ),
                    ),
                  ),
                  if (interactive) ...<Widget>[
                    const SizedBox(width: 3),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.textMuted,
                      size: 25,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DevelopmentBadge extends StatelessWidget {
  const _DevelopmentBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: AppText(
        '開發中',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: AppColors.warning,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AppNavigationBar extends StatelessWidget {
  const _AppNavigationBar({required this.selected, required this.onSelected});

  final AppSection selected;
  final ValueChanged<AppSection> onSelected;

  @override
  Widget build(BuildContext context) {
    // At accessibility sizes the label is intentionally kept visible rather
    // than clipped. Give the bar enough height for the scaled label plus its
    // icon; the page above remains scrollable.
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    var navigationHeight = textScale > 1.3 ? 84.0 : 68.0;
    final labelWidth = (MediaQuery.sizeOf(context).width - 44) / 4;
    for (final label in ['首頁', '辨識', '導航', '設定']) {
      final measure = TextPainter(
        text: TextSpan(
          text: context.tr(label),
          style: DefaultTextStyle.of(context).style.merge(
            const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: labelWidth > 1 ? labelWidth : 1);
      final requiredHeight = measure.height + 40; // icon, gap, padding, border
      if (requiredHeight > navigationHeight) navigationHeight = requiredHeight;
      measure.dispose();
    }
    return ColoredBox(
      color: AppColors.background,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Container(
          height: navigationHeight,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(28),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 18,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: <Widget>[
              _NavItem(
                section: AppSection.home,
                selected: selected,
                icon: Icons.home_outlined,
                label: '首頁',
                onSelected: onSelected,
              ),
              _NavItem(
                section: AppSection.explore,
                selected: selected,
                icon: Icons.visibility_rounded,
                label: '辨識',
                onSelected: onSelected,
              ),
              _NavItem(
                section: AppSection.navigation,
                selected: selected,
                icon: Icons.assistant_navigation,
                label: '導航',
                onSelected: onSelected,
              ),
              _NavItem(
                section: AppSection.settings,
                selected: selected,
                icon: Icons.settings_rounded,
                label: '設定',
                onSelected: onSelected,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.section,
    required this.selected,
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  final AppSection section;
  final AppSection selected;
  final IconData icon;
  final String label;
  final ValueChanged<AppSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final active = section == selected;
    return Expanded(
      child: Semantics(
        selected: active,
        button: true,
        label: context.tr(label),
        excludeSemantics: true,
        onTap: () => onSelected(section),
        child: InkWell(
          onTap: () => onSelected(section),
          borderRadius: BorderRadius.circular(23),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            constraints: const BoxConstraints(minHeight: 58),
            decoration: BoxDecoration(
              color: active ? AppColors.surfaceRaised : Colors.transparent,
              borderRadius: BorderRadius.circular(23),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  icon,
                  size: 25,
                  color: active ? AppColors.primary : AppColors.textMuted,
                ),
                const SizedBox(height: 2),
                AppText(
                  label,
                  style: TextStyle(
                    color: active ? AppColors.primary : AppColors.textMuted,
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
