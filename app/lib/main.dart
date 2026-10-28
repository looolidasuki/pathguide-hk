import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';

import 'ui/app_shell.dart';
import 'l10n/app_language.dart';
import 'ui/app_theme.dart';
import 'ui/demo_page.dart';
import 'settings/app_settings.dart';
import 'account/account_controller.dart';
import 'account/firebase_accounts.dart';
import 'account/account_ui.dart';
import 'photos/photo_controller.dart';
import 'photos/firebase_photos.dart';
import 'photos/photo_ui.dart';

/// 領路通 · PathGuide HK。
///
/// 任務首頁不啟動相機；使用者進入辨識頁後才請求權限並自動開始。
/// Android 與 iOS 的「探索」頁均使用原生相機及同一個裝置端模型，也可
/// 切換三類模擬框，並共用繁體中文閾值、標籤及粵語播報控制。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Preferences are loaded before the first UI frame, so the selected speech
  // speed applies to the very first Cantonese announcement after a relaunch.
  final settings = await AppSettings.load();

  // 室外强光下演示，深色系统栏更省电也更清楚。
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: AppColors.background,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.background,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  final account = await configuredAccounts();
  final photos = await configuredPhotos(account);
  runApp(PathGuideApp(settings: settings, account: account, photos: photos));
}

class PathGuideApp extends StatefulWidget {
  const PathGuideApp({
    super.key,
    this.initialMode = SourceMode.camera,
    this.initialSection = AppSection.home,
    this.settings,
    this.theme,
    this.account,
    this.photos,
  });

  final SourceMode initialMode;
  final AppSection initialSection;
  final AppSettings? settings;
  final ThemeData? theme;
  final AccountController? account;
  final PhotoController? photos;

  @override
  State<PathGuideApp> createState() => _PathGuideAppState();
}

class _PathGuideAppState extends State<PathGuideApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.photos?.foreground(state == AppLifecycleState.resumed);
  }

  late final AppSettings _settings = widget.settings ?? AppSettings.memory();

  late final AccountController _account =
      widget.account ?? unconfiguredAccounts();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.photos?.dispose();
    _account.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _settings,
    builder: (context, _) => _buildApp(context),
  );

  Widget _buildApp(BuildContext context) {
    final app = AccountScope(
      controller: _account,
      child: MaterialApp(
        title: '領路通',
        builder: (context, child) =>
            AppLanguageScope(language: _settings.language, child: child!),
        locale: _settings.language == AppLanguage.english
            ? const Locale('en')
            : const Locale.fromSubtags(
                languageCode: 'zh',
                scriptCode: 'Hant',
                countryCode: 'HK',
              ),
        supportedLocales: const <Locale>[
          Locale('en'),
          Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hant',
            countryCode: 'HK',
          ),
        ],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        debugShowCheckedModeBanner: false,
        theme: widget.theme ?? buildAppTheme(),
        home: AppShell(
          initialSection: widget.initialSection,
          initialVisionMode: widget.initialMode,
          settings: _settings,
        ),
      ),
    );
    return widget.photos == null
        ? app
        : PhotoScope(controller: widget.photos!, child: app);
  }
}
