import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/menu/menu_document.dart';

MenuLine line(
  String text, {
  double x = .1,
  double y = .1,
  double w = .3,
  double h = .03,
  int page = 1,
  double confidence = .95,
}) => MenuLine(
  text: text,
  page: page,
  left: x,
  top: y,
  width: w,
  height: h,
  confidence: confidence,
);
void main() {
  test('phone geometry pairs three-column dishes despite vertical boxes and covered glyphs', () {
    final fixture = jsonDecode(
      File('test/fixtures/menu/dense-menu.iphone-selected.json')
          .readAsStringSync(),
    ) as Map;
    final d = parseMenu(
      (fixture['lines'] as List)
          .map((l) => MenuLine.fromMap(l as Map))
          .toList(),
      pages: 1,
    );
    for (final dish in ['干炒豬扒烏冬', '星洲炒烏冬', '干炒三絲烏冬', '肉絲燴伊麵']) {
      expect(d.search(dish).single.prices.map(normalizeMenuText), [
        '58',
      ], reason: dish);
    }
    expect(d.search('豉油皇牛肉炒麵').single.prices, ['\$56']);
    expect(d.search('生炒排骨飯').single.prices, ['\$54']);
    expect(d.search('豬扒葡雙蛋飯').single.prices, ['\$54']);
    expect(d.search('炸雞脾飯').single.prices, ['\$54']);
    expect(d.original, contains('茄芝主娟老芝'));
  });
  test('covered glyph does not create a second candidate but distinct adjacent dishes stay ambiguous', () {
    final d = parseMenu([
      line('星洲炒烏冬', w: .3),
      line('星', w: .035),
      line('\$58', x: .45, w: .07),
    ], pages: 1);
    expect(d.search('星洲炒烏冬').single.prices, ['\$58']);
    expect(d.entries.where((e) => e.text == '星'), isEmpty);
    final ambiguous = parseMenu([
      line('牛腩飯', w: .12),
      line('叉燒飯', x: .23, w: .12),
      line('\$58', x: .42, w: .07),
    ], pages: 1);
    expect(ambiguous.search('牛腩飯').single.prices, isEmpty);
    expect(ambiguous.search('叉燒飯').single.prices, isEmpty);
  });
  test('deduplication does not erase conflicting price readings', () {
    final d = parseMenu([
      line('三文治'),
      line('雙拼 \$3', x: .7, y: .14, w: .18),
      line('雙拼 \$33', x: .7, y: .14, w: .18),
    ], pages: 1);
    expect(d.search('三文治').single.prices, isEmpty);
    expect(d.search('三文治').single.text, contains('辨識有分歧'));
  });

  test(
    'contextual grayscale OCR fixture keeps all sandwich variant prices',
    () {
      final fixture = jsonDecode(
        File('test/fixtures/menu/tea-menu.price-crops.macos-vision.json')
            .readAsStringSync(),
      ) as Map;
      final d = parseMenu(
        (fixture['lines'] as List)
            .map((l) => MenuLine.fromMap(l as Map))
            .toList(),
        pages: 1,
        engineVersion: fixture['ocrVersion'] as String,
      );
      expect(
        d.search('三文治').single.prices,
        containsAll(['\$31', '\$33', '\$36']),
      );
      expect(d.diagnostics, contains('2026-10-23.price-crops.1'));
    },
  );

  test('joins a detected currency symbol and full-width amount without changing raw OCR', () {
    final d = parseMenu(
      [
        line('三文治'),
        line('單拼', x: .7, w: .07),
        line('＄', x: .82, w: .015, h: .02),
        line('３１', x: .845, w: .05, h: .02),
      ],
      pages: 1,
      engineVersion: 'price-test',
    );
    expect(d.search('三文治').single.prices, ['\$31']);
    expect(d.original, contains('３１'));
    expect(d.original, isNot(contains('＄３１')));
    expect(d.diagnostics, contains('price-test'));
    expect(d.diagnostics, contains('完整價錢標記：1'));
  });
  test('bare numbers and S misreadings never become invented prices', () {
    final d = parseMenu([
      line('三文治'),
      line('單拼', x: .7, w: .07),
      line('31', x: .85, w: .06),
      line('雙拼', x: .7, y: .17, w: .07),
      line('S33', x: .85, y: .17, w: .06),
    ], pages: 1);
    expect(d.search('三文治').single.prices, isEmpty);
    expect(d.diagnostics, contains('未帶貨幣符號的數字段數：1'));
  });
  test('split currency cannot borrow another row or page amount', () {
    final d = parseMenu([
      line('三文治'),
      line('單拼', x: .7, w: .07),
      line('\$', x: .82, w: .015, h: .02),
      line('31', x: .845, y: .18, w: .05, h: .02),
      line('99', x: .845, w: .05, h: .02, page: 2),
    ], pages: 2);
    expect(d.search('三文治').single.prices, isEmpty);
  });
  test(
    'ambiguous neighbouring numbers are not joined to a currency symbol',
    () {
      final d = parseMenu([
        line('三文治'),
        line('單拼', x: .7, w: .07),
        line('\$', x: .82, w: .015, h: .02),
        line('31', x: .845, w: .02, h: .02),
        line('33', x: .867, w: .02, h: .02),
      ], pages: 1);
      expect(d.search('三文治').single.prices, isEmpty);
    },
  );

  test(
    'conflicting readings of one variant never become a confirmed price',
    () {
      final d = parseMenu([
        line('三文治'),
        line('雙拼 \$3', x: .7, y: .14, w: .18),
        line('雙拼 \$33', x: .7, y: .14, w: .18),
      ], pages: 1);
      expect(d.search('三文治').single.prices, isEmpty);
      expect(d.search('三文治').single.text, contains('辨識有分歧'));
    },
  );

  test('actual tea menu OCR links sandwich variants without confusing supplement or toast prices', () {
    final fixture = jsonDecode(
      File('test/fixtures/menu/tea-menu.macos-vision.json').readAsStringSync(),
    ) as Map;
    final d = parseMenu(
      (fixture['lines'] as List)
          .map((l) => MenuLine.fromMap(l as Map))
          .toList(),
      pages: 1,
    );
    final sandwich = d.search('三文治').single;
    expect(sandwich.text, contains('單拼 \$31'));
    expect(sandwich.text, contains('雙拼 \$33'));
    expect(sandwich.text, contains('三拼 \$36'));
    expect(sandwich.text, contains('加\$3'));
    expect(sandwich.text, isNot(contains('\$26')));
    expect(sandwich.text, isNot(contains('\$28')));
    final toast = d.search('多士餐').single;
    expect(toast.prices, containsAll(['\$26', '\$28']));
    expect(d.search('奶油脆豬').single.prices, ['＄30']);
    expect(d.search('花生醬西多士').single.prices, ['\$35']);
    // Bracketed numbered sets have no explicit row-by-row price evidence.
    expect(d.search('雞扒配西多士').single.prices, isEmpty);
    expect(d.search('吉列魚柳配西多士').single.prices, isEmpty);
  });
  test('actual dense low-resolution menu retains readable rows without fabricating missing dishes', () {
    final fixture = jsonDecode(
      File('test/fixtures/menu/dense-menu.macos-vision.json')
          .readAsStringSync(),
    ) as Map;
    final d = parseMenu(
      (fixture['lines'] as List)
          .map((l) => MenuLine.fromMap(l as Map))
          .toList(),
      pages: 1,
    );
    expect(d.entries, isNotEmpty);
    expect(d.entries.where((e) => e.prices.isNotEmpty), isNotEmpty);
    expect(d.original, contains('中式飯類'));
    expect(d.search('不存在的菜式'), isEmpty);
  });
  test('missing variant price stays unknown and never borrows the next section price', () {
    final d = parseMenu([
      line('三文治', y: .1),
      line('單拼', x: .7, y: .1, w: .08),
      line('雙拼', x: .7, y: .16, w: .08),
      line('\$33', x: .85, y: .16, w: .07),
      line('多士餐/方包', y: .3),
      line('單拼', x: .7, y: .3, w: .08),
      line('\$26', x: .85, y: .3, w: .07),
    ], pages: 1);
    final sandwich = d.search('三文治').single;
    expect(sandwich.text, contains('單拼價錢未能確認'));
    expect(sandwich.prices, ['\$33']);
  });
  test(
    'joins spaced glyphs before pairing a same-row full-width currency price',
    () {
      final d = parseMenu([
        line('牛', x: .1, w: .025),
        line('腩', x: .13, w: .025),
        line('飯', x: .16, w: .025),
        line('＄56', x: .2, w: .08),
      ], pages: 1);
      expect(d.search('牛腩飯').single.prices, ['＄56']);
    },
  );

  test('normalizes full Cantonese utterances before extracting the dish', () {
    for (final phrase in [
      '三文治',
      '我想食三文治',
      '我想食，三文治',
      '唔該，我想食 三文治呀',
      '請問我想食三文治幾多錢？',
    ]) {
      expect(menuQueryFromSpeech(phrase), '三文治', reason: phrase);
    }
    expect(menuQueryFromSpeech('我想食牛腩饭'), '牛腩飯');
  });

  test('spoken Cantonese request extracts dish without changing its name', () {
    expect(menuQueryFromSpeech('我想食牛腩飯'), '牛腩飯');
    expect(menuQueryFromSpeech('唔該幫我搵叉燒飯幾錢？'), '叉燒飯');
    expect(menuQueryFromSpeech('有冇凍檸茶呀'), '凍檸茶');
    expect(menuQueryFromSpeech('我想食'), '');
  });
  test(
    'categorizes explicit headings, finds dish and preserves price conditions',
    () {
      final d = parseMenu([
        line('午餐'),
        line('牛腩飯 HK\$48 起，凍飲加 3 元', y: .2),
        line('雞扒飯 \$52', y: .3),
        line('飲品', y: .4),
        line('凍檸茶 \$18', y: .5),
      ], pages: 1);
      expect(d.sections, ['午餐', '飲品']);
      final result = d.search('牛腩飯');
      expect(result.length, 1);
      expect(result.single.prices, ['HK\$48 起', '3 元']);
      expect(result.single.spoken, contains('凍飲加 3 元'));
      expect(d.search('不存在'), isEmpty);
    },
  );
  test(
    'pairs one neighbouring price, does not guess price from a different row',
    () {
      final d = parseMenu([
        line('牛腩飯', x: .1, w: .3),
        line('\$48', x: .5, w: .1),
        line('叉燒飯', y: .3),
        line('\$99', x: .5, y: .5),
      ], pages: 1);
      expect(d.search('牛腩飯').single.prices, ['\$48']);
      expect(d.search('叉燒飯').single.prices, isEmpty);
      expect(d.search('叉燒飯').single.spoken, contains('未能確認價錢'));
    },
  );
  test('ambiguous row cannot attach the same price to multiple dishes', () {
    final d = parseMenu([
      line('牛腩飯', x: .1, w: .15),
      line('叉燒飯', x: .26, w: .15),
      line('\$48', x: .43, w: .1),
    ], pages: 1);
    expect(d.search('牛腩飯').single.prices, isEmpty);
    expect(d.search('叉燒飯').single.prices, isEmpty);
  });
  test(
    'keeps columns and pages separate, unknown numbers do not become prices',
    () {
      final d = parseMenu([
        line('午餐'),
        line('牛腩飯 48', y: .2),
        line('飲品', x: .6),
        line('咖啡 \$18', x: .6, y: .2),
        line('\$88', page: 2),
      ], pages: 2);
      expect(d.search('牛腩飯').single.section, '午餐');
      expect(d.search('牛腩飯').single.prices, isEmpty);
      expect(d.search('咖啡').single.section, '飲品');
      expect(d.original, contains('第 2 頁：\$88'));
    },
  );
  test('low confidence and truncation are visible rather than fabricated completeness', () {
    final d = parseMenu(
      [line('牛腩飯 \$48', confidence: .3)],
      pages: 3,
      truncated: true,
    );
    expect(d.truncated, true);
    expect(d.entries.single.spoken, contains('可能有誤'));
    expect(normalizeMenuText(' 牛腩饭！ '), normalizeMenuText('牛腩飯'));
  });
}
