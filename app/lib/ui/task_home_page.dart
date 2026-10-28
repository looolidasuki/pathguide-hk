import '../l10n/app_language.dart';

import 'package:flutter/material.dart';

import 'usage_guide.dart';
import '../account/account_ui.dart';

class TaskHomePage extends StatelessWidget {
  const TaskHomePage({
    super.key,
    required this.onExplore,
    required this.onNavigation,
    required this.onSettings,
    required this.onAccount,
    required this.onMenu,
  });

  final VoidCallback onExplore;
  final VoidCallback onNavigation;
  final VoidCallback onSettings;
  final VoidCallback onAccount;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ListView(
      key: const ValueKey('task-home'),
      padding: const EdgeInsets.all(20),
      children: <Widget>[
        Semantics(
          header: true,
          child: AppText(
            '領路通',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ),
        const SizedBox(height: 12),
        const AppText('先選擇任務。基本辨識毋須登入，也不會儲存或上傳相片。'),
        const SizedBox(height: 24),
        _task('即時辨識', Icons.visibility_rounded, onExplore),
        _task('路線導航', Icons.navigation_outlined, onNavigation),
        _task('菜單閱讀與語音搜尋', Icons.restaurant_menu, onMenu),
        _task('設定與使用教學', Icons.settings_outlined, onSettings),
        AccountEntry(onManage: onAccount),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => showUsageGuide(context),
          child: const AppText('閱讀首次使用教學'),
        ),
      ],
    ),
  );

  Widget _task(String title, IconData icon, VoidCallback onPressed) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: FilledButton.icon(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(72),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        alignment: Alignment.centerLeft,
      ),
      onPressed: onPressed,
      icon: ExcludeSemantics(child: Icon(icon)),
      label: AppText(title),
    ),
  );
}
