import '../l10n/app_language.dart';

import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import 'app_theme.dart';
import 'demo_page.dart';
import 'task_home_page.dart';
import 'usage_guide.dart';
import 'developer_testing_page.dart';
import 'task_introduction.dart';
import '../route_memory/route_capture_page.dart';
import '../account/account_ui.dart';
import '../menu/menu_page.dart';
import '../navigation/navigation_page.dart';
import '../navigation/navigation_hub_page.dart';
import '../route_memory/route_journey_page.dart';
import '../indoor/graph_replay_page.dart';
import '../depth/depth_page.dart';
import '../route_memory/route_memory_contract.dart';
import '../route_memory/route_memory_mock_page.dart';

enum AppSection {
  home,
  explore,
  navigation,
  outdoor,
  settings,
  developer,
  visionDiagnostics,
}

/// Main product shell. Outgoing tasks are disposed before another task opens.
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
  bool _routeMemoryVisible = false;
  final _routeMemory = RouteMemoryController();

  @override
  void dispose() {
    _routeMemory.dispose();
    super.dispose();
  }

  bool _navigationTask = false, _confirmingNavigationExit = false;
  Future<void> _select(AppSection section) async {
    if (_section == section &&
        !_accountVisible &&
        !_menuVisible &&
        !_graphVisible &&
        !_depthVisible &&
        !_routeMemoryVisible) {
      return;
    }
    if (_section == AppSection.outdoor &&
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
    _routeMemory.pause();
    setState(() {
      _section = section;
      _accountVisible = false;
      _menuVisible = false;
      _graphVisible = false;
      _depthVisible = false;
      _routeMemoryVisible = false;
    });
  }

  bool _openingTask = false;
  Future<void> _openTask(AppTask task, VoidCallback open) async {
    if (_openingTask) return;
    _openingTask = true;
    try {
      if (!widget.settings.hasTaskIntroduction(task)) {
        final proceed = await showTaskIntroduction(context, task);
        if (proceed != true || !mounted) return;
        await widget.settings.completeTaskIntroduction(task);
      }
      if (mounted) open();
    } finally {
      _openingTask = false;
    }
  }

  void _openRoutes(bool recording) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => RouteJourneyPage(
        settings: widget.settings,
        initialRecording: recording,
      ),
    ),
  );

  void _openAccount() => setState(() => _accountVisible = true);

  Widget _page() => switch (_section) {
    AppSection.home => TaskHomePage(
      onExplore: () =>
          _openTask(AppTask.recognition, () => _select(AppSection.explore)),
      onNavigation: () =>
          _openTask(AppTask.navigation, () => _select(AppSection.navigation)),
      onSettings: () => _select(AppSection.settings),
      onMenu: () =>
          _openTask(AppTask.menu, () => setState(() => _menuVisible = true)),
    ),
    AppSection.explore => DemoPage(
      initialMode: widget.initialVisionMode,
      settings: widget.settings,
      onBack: () => _select(AppSection.home),
    ),
    AppSection.navigation => NavigationHubPage(
      settings: widget.settings,
      onSearch: () => _select(AppSection.outdoor),
      onLibrary: () => _openRoutes(false),
      onRecord: () => _openRoutes(true),
      onBack: () => _select(AppSection.home),
    ),
    AppSection.outdoor => NavigationPage(
      settings: widget.settings,
      onTaskChanged: (active) => _navigationTask = active,
      speechSuspended: _confirmingNavigationExit,
      onBack: () => _select(AppSection.navigation),
    ),
    AppSection.settings => SettingsPage(
      onAccount: _openAccount,
      onBack: () => _select(AppSection.home),
      onDeveloperTesting: () => _select(AppSection.developer),
      settings: widget.settings,
    ),
    AppSection.developer => DeveloperTestingPage(
      onBack: () => _select(AppSection.settings),
      onCamera: () => _openTask(
        AppTask.routeCamera,
        () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (routeContext) => RouteCapturePage(
              settings: widget.settings,
              onBack: () => Navigator.of(routeContext).pop(),
            ),
          ),
        ),
      ),
      onRouteMock: () => _openTask(
        AppTask.routeMock,
        () => setState(() => _routeMemoryVisible = true),
      ),
      onReplay: () => _openTask(
        AppTask.landmarkReplay,
        () => setState(() => _graphVisible = true),
      ),
      onDepth: () =>
          _openTask(AppTask.depth, () => setState(() => _depthVisible = true)),
      onVisionDiagnostics: () => _openTask(
        AppTask.visionDiagnostics,
        () => _select(AppSection.visionDiagnostics),
      ),
    ),
    AppSection.visionDiagnostics => DemoPage(
      initialMode: widget.initialVisionMode,
      settings: widget.settings,
      developerControls: true,
      onBack: () => _select(AppSection.developer),
    ),
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Dispose the outgoing camera immediately. An AnimatedSwitcher would
      // keep it alive (and potentially speaking) during its exit animation.
      body: KeyedSubtree(
        key: ValueKey(
          _routeMemoryVisible
              ? 'route-memory-mock'
              : _depthVisible
              ? 'depth'
              : _graphVisible
              ? 'graph-replay'
              : _menuVisible
              ? 'menu'
              : _accountVisible
              ? 'account'
              : _section,
        ),
        child: _routeMemoryVisible
            ? RouteMemoryMockPage(
                controller: _routeMemory,
                settings: widget.settings,
                onBack: () => setState(() => _routeMemoryVisible = false),
              )
            : _depthVisible
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
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    this.onAccount,
    super.key,
    this.onBack,
    this.onDeveloperTesting,
    required this.settings,
  });

  final VoidCallback? onBack;
  final VoidCallback? onDeveloperTesting;
  final AppSettings settings;
  final VoidCallback? onAccount;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppSettings get settings => widget.settings;
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
                if (widget.onBack != null)
                  IconButton(
                    tooltip: context.tr('返回首頁'),
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back),
                  ),
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
              '調整語言及語速，查看帳號、教學和私隱。',
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
              title: '語音',
              children: <Widget>[
                _NativeSettingsRow(
                  key: const ValueKey<String>('speech-speed-row'),
                  icon: Icons.volume_up_rounded,
                  title: '播報速度',
                  value: settings.speechSpeed.label,
                  semanticLabel: '播報速度，目前為 ${settings.speechSpeed.label}',
                  onTap: () => _showSpeechSpeedPicker(context),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (widget.onDeveloperTesting != null) ...[
              OutlinedButton.icon(
                onPressed: widget.onDeveloperTesting,
                icon: const Icon(Icons.science_outlined),
                label: const AppText('開發測試'),
              ),
              const AppText('相機試驗、合成樣例及診斷工具；不提供室內導航。'),
              const SizedBox(height: 24),
            ],
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
