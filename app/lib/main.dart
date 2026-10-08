import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/app_locale.dart';
import 'l10n/app_strings.dart';
import 'ui/demo_page.dart';

/// 領路通 · PathGuide HK —— M3 最小可见 Demo。
///
/// UI 与 TTS 跟随手机系统语言；不支持的语言回落到英语。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppLocale.current = AppLocale.resolve();

  // 室外强光下演示，深色系统栏更省电也更清楚。
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Color(0xFF161B22),
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF161B22),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(const PathGuideApp());
}

class PathGuideApp extends StatefulWidget {
  const PathGuideApp({super.key});

  @override
  State<PathGuideApp> createState() => _PathGuideAppState();
}

class _PathGuideAppState extends State<PathGuideApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppLocale.current = AppLocale.resolve();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    final next = locales != null && locales.isNotEmpty
        ? AppLocale.resolve(locales.first)
        : AppLocale.resolve();
    if (next != AppLocale.current) {
      setState(() => AppLocale.current = next);
    } else {
      // Still rebuild so Material widgets pick up the new Locale.
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppStrings.current.appTitle,
      debugShowCheckedModeBanner: false,
      // Never pin a fixed locale: let the OS decide, then resolve.
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: Brightness.dark,
        ),
      ),
      supportedLocales: const <Locale>[
        Locale('en'),
        Locale('zh'),
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        Locale('zh', 'HK'),
        Locale('zh', 'TW'),
        Locale('zh', 'CN'),
        Locale('yue'),
      ],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      localeResolutionCallback: (locale, supported) {
        return AppLocale.applyResolved(locale, supported);
      },
      home: const DemoPage(),
    );
  }
}
