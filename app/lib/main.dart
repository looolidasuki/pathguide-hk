import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/app_locale.dart';
import 'l10n/app_strings.dart';
import 'settings/app_settings.dart';
import 'ui/home_page.dart';

/// 領路通 · PathGuide HK —— M3 最小可见 Demo。
///
/// UI 与 TTS 跟随手机系统语言；不支持的语言回落到英语。
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLocale.current = AppLocale.resolve();

  // 讀設定要 await：語速必須在第一句播報之前就位。
  //
  // 但**啟動不可以死在這裡**。`SharedPreferences.getInstance()` 會拋
  // （平台通道沒接上 → MissingPluginException、儲存檔毀損、權限被拒），
  // 而這一行在 `runApp` **之前**：拋出去就等於既沒有畫面也沒有語音——
  // 看不見的使用者拿到的是一支不說話的死機，而且沒有任何出口可以離開。
  // 所以失敗一律退回純記憶體的一份：語速回到預設（「正常」），
  // 引導／讀字／障礙物播報完全照常。成功時行為一個字都沒變。
  AppSettings settings;
  try {
    settings = await AppSettings.load();
  } catch (e) {
    // 不彈窗、不擋路：只留一行 log，讓使用者照樣進得了主界面。
    debugPrint('[PathGuide] 讀取設定失敗（已忽略，改用預設語速）：$e');
    settings = AppSettings.memory();
  }

  // 室外强光下演示，深色系统栏更省电也更清楚。
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Color(0xFF161B22),
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF161B22),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(PathGuideApp(settings: settings));
}

class PathGuideApp extends StatefulWidget {
  const PathGuideApp({super.key, this.settings});

  /// 使用者設定。`main` 讀完就注入；沒注入時首頁自己建純記憶體的一份。
  final AppSettings? settings;

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
      home: HomePage(settings: widget.settings),
    );
  }
}
