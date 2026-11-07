import '../l10n/app_language.dart';

import 'package:flutter/material.dart';

class TaskHomePage extends StatelessWidget {
  const TaskHomePage({
    super.key,
    required this.onExplore,
    required this.onNavigation,
    required this.onSettings,
    required this.onMenu,
  });

  final VoidCallback onExplore;
  final VoidCallback onNavigation;
  final VoidCallback onSettings;
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
        _task(
          '即時辨識',
          '用相機辨識支援的物件，聽取簡短結果。',
          Icons.visibility_rounded,
          onExplore,
        ),
        _task(
          '路線導航',
          '搜尋戶外目的地，或錄製室內路標路線。',
          Icons.navigation_outlined,
          onNavigation,
        ),
        _task('菜單閱讀與語音搜尋', '拍攝菜單，查詢菜名及價格。', Icons.restaurant_menu, onMenu),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onSettings,
          icon: const Icon(Icons.settings_outlined),
          label: const AppText('設定與使用教學'),
        ),
      ],
    ),
  );

  Widget _task(
    String title,
    String description,
    IconData icon,
    VoidCallback onPressed,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: FilledButton.icon(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(72),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        alignment: Alignment.centerLeft,
      ),
      onPressed: onPressed,
      icon: ExcludeSemantics(child: Icon(icon)),
      label: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          AppText(description, style: const TextStyle(fontSize: 15)),
        ],
      ),
    ),
  );
}
