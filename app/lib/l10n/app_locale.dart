import 'dart:ui' show Locale, PlatformDispatcher;

/// App UI / TTS language bucket.
///
/// Only two UI string packs ship: English (default) and Hong Kong
/// Traditional Chinese ([zh]). System locales `zh-*` / `yue` all map to [zh];
/// every other language falls back to [en]. Extra entries in
/// `MaterialApp.supportedLocales` only help Flutter's built-in widgets
/// (dialogs, date pickers) — they are not separate copy packs.
enum AppLanguage {
  en,
  zh,
}

/// Resolve and hold the active [AppLanguage] from the phone system locale.
abstract final class AppLocale {
  /// Currently active language. Updated when the app starts and when
  /// [MaterialApp] resolves a locale.
  static AppLanguage current = resolve();

  /// Map a device/system [Locale] to a supported app language.
  ///
  /// Unsupported languages fall back to English — never force Chinese
  /// when the phone is set to something else.
  static AppLanguage resolve([Locale? locale]) {
    final Locale l = locale ?? PlatformDispatcher.instance.locale;
    final code = l.languageCode.toLowerCase();
    if (code == 'zh' || code == 'yue') return AppLanguage.zh;
    return AppLanguage.en;
  }

  /// Apply a resolved locale (call from [MaterialApp.localeResolutionCallback]).
  static Locale applyResolved(Locale? device, Iterable<Locale> supported) {
    final lang = resolve(device);
    current = lang;
    if (lang == AppLanguage.zh) {
      // Keep region when the system already sent a Chinese locale.
      if (device != null &&
          (device.languageCode == 'zh' || device.languageCode == 'yue')) {
        return device;
      }
      return const Locale('zh');
    }
    return const Locale('en');
  }

  static bool get isChinese => current == AppLanguage.zh;
}
