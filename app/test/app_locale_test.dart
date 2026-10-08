import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';

import 'package:pathguide/l10n/app_locale.dart';
import 'package:pathguide/l10n/app_strings.dart';

void main() {
  group('UI language follows system locale', () {
    test('unsupported system language falls back to English', () {
      expect(AppLocale.resolve(const Locale('ja')), AppLanguage.en);
      expect(AppLocale.resolve(const Locale('fr', 'FR')), AppLanguage.en);
      expect(AppLocale.resolve(const Locale('en', 'US')), AppLanguage.en);
      expect(AppLocale.resolve(const Locale('de')), AppLanguage.en);
    });

    test('Chinese family (incl. yue) maps to zh UI pack', () {
      expect(AppLocale.resolve(const Locale('zh', 'HK')), AppLanguage.zh);
      expect(AppLocale.resolve(const Locale('zh', 'CN')), AppLanguage.zh);
      expect(AppLocale.resolve(const Locale('zh', 'TW')), AppLanguage.zh);
      expect(AppLocale.resolve(const Locale('yue')), AppLanguage.zh);
      expect(AppLocale.resolve(const Locale('yue', 'HK')), AppLanguage.zh);
    });

    test('applyResolved keeps Chinese region and defaults English', () {
      final zhHk = AppLocale.applyResolved(
        const Locale('zh', 'HK'),
        const <Locale>[Locale('en'), Locale('zh', 'HK')],
      );
      expect(zhHk, const Locale('zh', 'HK'));
      expect(AppLocale.current, AppLanguage.zh);

      final yue = AppLocale.applyResolved(
        const Locale('yue'),
        const <Locale>[Locale('en'), Locale('yue'), Locale('zh')],
      );
      expect(yue.languageCode, anyOf('yue', 'zh'));
      expect(AppLocale.current, AppLanguage.zh);

      final en = AppLocale.applyResolved(
        const Locale('ja'),
        const <Locale>[Locale('en'), Locale('zh'), Locale('yue')],
      );
      expect(en, const Locale('en'));
      expect(AppLocale.current, AppLanguage.en);
    });

    test('pinned MaterialApp.locale would break this contract — resolve is source of truth',
        () {
      // Guard: if someone later hard-codes `locale: Locale('zh')` on
      // MaterialApp, product behaviour still goes through resolve() for
      // AppStrings. This test documents that ja must never yield zh.
      expect(AppLocale.resolve(const Locale('ja')), isNot(AppLanguage.zh));
      expect(AppLocale.resolve(const Locale('yue')), isNot(AppLanguage.en));
    });
  });

  group('Chinese UI pack is Hong Kong Traditional', () {
    test('key UI strings use Traditional forms', () {
      final s = AppStrings.of(AppLanguage.zh);
      expect(s.boxes, '檢測框');
      expect(s.camera, '相機');
      expect(s.mockSelectCamera, contains('模擬'));
      expect(s.mockSelectCamera, contains('相機'));
      expect(s.voice, '語音');
      expect(s.modelNotLoaded, contains('載入'));
      expect(s.reasonSkipPrefix, '跳過：');
      expect(s.appTitle, '領路通');
    });

    test('Chinese pack avoids common Simplified characters', () {
      final s = AppStrings.of(AppLanguage.zh);
      final samples = <String>[
        s.boxes,
        s.camera,
        s.mockSelectCamera,
        s.voice,
        s.modelNotLoaded,
        s.modelLoaded(classCount: 1, inputSize: '1'),
        s.reasonSkipPrefix,
        s.geometryMismatch(1, 1, 2, 2),
        s.webCameraNeedsHttps,
      ];
      // Multi-char Simplified forms that must not appear in the HK pack.
      const simplifiedMarkers = <String>[
        '检测',
        '模拟',
        '相机',
        '语音',
        '加载',
        '几何',
        '浏览器',
        '实时',
        '显示',
        '隐藏',
        '错误',
        '输入',
        '输出',
        '跳过',
      ];
      for (final text in samples) {
        for (final marker in simplifiedMarkers) {
          expect(text.contains(marker), isFalse,
              reason: '「$marker」 in "$text"');
        }
      }
    });

    test('English pack stays English for the same keys', () {
      final s = AppStrings.of(AppLanguage.en);
      expect(s.boxes, 'Boxes');
      expect(s.camera, 'Camera');
      expect(s.appTitle, 'PathGuide');
    });
  });
}
