const menuParserVersion = '2026-10-23.phone-pairing.1';

class MenuLine {
  const MenuLine({
    required this.text,
    required this.page,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.confidence,
  });
  final String text;
  final int page;
  final double left, top, width, height, confidence;
  factory MenuLine.fromMap(Map<dynamic, dynamic> m) => MenuLine(
    text: (m['text'] as String).trim(),
    page: (m['page'] as num).toInt(),
    left: (m['left'] as num).toDouble(),
    top: (m['top'] as num).toDouble(),
    width: (m['width'] as num).toDouble(),
    height: (m['height'] as num).toDouble(),
    confidence: (m['confidence'] as num).toDouble(),
  );
}

class MenuEntry {
  const MenuEntry({
    required this.text,
    required this.section,
    required this.page,
    required this.uncertain,
  });
  final String text, section;
  final int page;
  final bool uncertain;
  List<String> get prices =>
      pricePattern.allMatches(text).map((m) => m.group(0)!.trim()).toList();
  String get name {
    final m = pricePattern.firstMatch(text);
    return m != null && m.start > 0
        ? text.substring(0, m.start).replaceAll(RegExp(r'[.．…\s]+$'), '').trim()
        : text;
  }

  String get spoken => prices.isEmpty
      ? '$text。未能確認價錢。'
      : '標示內容：$text。${prices.length > 1 ? "包含多個價格，請核對相應選項。" : ""}${uncertain ? "文字可能有誤，請核對原文或重拍。" : ""}';
}

final pricePattern = RegExp(
  r'(?:HK\s*[\$＄﹩]|港幣\s*|[\$＄﹩])\s*\d+(?:[.,]\d{1,2})?(?:\s*(?:起|元|圓|蚊))?|\d+(?:[.,]\d{1,2})?\s*(?:元|圓|蚊)',
  caseSensitive: false,
);
bool _priceOnly(String s) =>
    s.replaceAll(pricePattern, '').replaceAll(RegExp(r'[\s.．…]'), '').isEmpty &&
    pricePattern.hasMatch(s);

class MenuDocument {
  const MenuDocument({
    required this.entries,
    required this.original,
    required this.pages,
    required this.truncated,
    this.warnings = const [],
    this.diagnostics = '',
  });
  final List<String> warnings;
  final String diagnostics;
  final List<MenuEntry> entries;
  final String original;
  final int pages;
  final bool truncated;
  List<String> get sections => entries.map((e) => e.section).toSet().toList();
  List<MenuEntry> search(String query, {String? section}) {
    final q = normalizeMenuText(query);
    return entries
        .where(
          (e) =>
              (section == null || e.section == section) &&
              (q.isEmpty || normalizeMenuText(e.text).contains(q)),
        )
        .toList();
  }
}

String normalizeMenuText(String s) => s
    .toLowerCase()
    .replaceAll('饭', '飯')
    .replaceAll('面', '麵')
    .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
String menuQueryFromSpeech(String s) {
  var q = normalizeMenuText(s)
      .replaceAll('请', '請')
      .replaceAll('吗', '嗎')
      .replaceAll('钱', '錢')
      .replaceAll('价', '價')
      .replaceAll('饮', '飲')
      .replaceAll('唔该', '唔該');
  for (final prefix in [
    '唔該',
    '請問',
    '麻煩',
    '幫我搵吓',
    '幫我搵',
    '幫我找',
    '我想食',
    '我想吃',
    '我想飲',
    '我想喝',
    '我想要',
    '我要',
    '有沒有',
    '有冇',
    '想食',
    '想吃',
  ]) {
    if (q.startsWith(prefix)) q = q.substring(prefix.length).trim();
  }
  return q
      .replaceAll(RegExp(r'(?:幾多錢|幾錢|多少錢|價錢|可以食)?[呀啊啦嗎呢喎。？！?!\s]*$'), '')
      .trim();
}

MenuDocument parseMenu(
  List<MenuLine> source, {
  required int pages,
  bool truncated = false,
  List<String> warnings = const [],
  String engineVersion = 'unknown',
}) {
  final valid = source
      .where(
        (l) =>
            l.text.isNotEmpty &&
            [
              l.left,
              l.top,
              l.width,
              l.height,
              l.confidence,
            ].every((v) => v.isFinite) &&
            l.width > 0 &&
            l.height > 0,
      )
      .toList();
  final canonical = valid
      .map(
        (l) => MenuLine(
          text: _priceCharacters(l.text),
          page: l.page,
          left: l.left,
          top: l.top,
          width: l.width,
          height: l.height,
          confidence: l.confidence,
        ),
      )
      .toList();
  final cleaned = _removeCoveredMenuFragments(canonical);
  final lines = _joinMenuFragments(_joinPriceFragments(cleaned));
  final priceColumns = _menuPriceColumns(lines);
  final paired = <MenuLine, String>{};
  final consumed = <MenuLine>{};
  // Pair only a price to its single unambiguous neighbouring text on the left.
  for (final price in lines.where((l) => _priceOnly(l.text))) {
    bool sameRow(MenuLine l) =>
        (price.top + price.height / 2 - l.top - l.height / 2).abs() <=
        (price.height > l.height ? price.height : l.height) * 0.6;
    var candidates = lines
        .where(
          (l) =>
              l.page == price.page &&
              // Tall vertical OCR boxes can span several dish rows.
              l.height <= price.height * 3 &&
              price.height <= l.height * 3 &&
              _samePriceColumn(
                l,
                price,
                priceColumns[price.page] ?? const [],
              ) &&
              !_priceOnly(l.text) &&
              !pricePattern.hasMatch(l.text) &&
              !RegExp(r'^(?:[A-Z]|價錢辨識有分歧.*)$').hasMatch(l.text.trim()) &&
              (price.left - l.left - l.width) >= -0.01 &&
              (price.left - l.left - l.width) <=
                  (l.height >= .025 ? .60 : .20) &&
              sameRow(l),
        )
        .toList();
    // Explicit option labels take priority over neighbouring ingredient prose.
    final optionLabels = candidates
        .where((l) => _optionName(l.text) != null)
        .toList();
    if (optionLabels.isNotEmpty) candidates = optionLabels;
    // A price printed midway beside a numbered list may apply to the whole
    // bracketed set. Never attach it only to the middle dish.
    candidates = candidates
        .where(
          (l) =>
              !_numbered(l.text) ||
              !lines.any(
                (n) =>
                    n != l &&
                    n.page == l.page &&
                    _numbered(n.text) &&
                    (n.left - l.left).abs() < .06 &&
                    (n.top - l.top).abs() < l.height * 2.5 &&
                    !lines.any(
                      (p) =>
                          p.page == n.page &&
                          _priceOnly(p.text) &&
                          p.left > n.left + n.width &&
                          (p.top + p.height / 2 - n.top - n.height / 2).abs() <
                              n.height * .6,
                    ),
              ),
        )
        .toList();
    if (candidates.length == 1 && !paired.containsKey(candidates.single)) {
      paired[candidates.single] = '${candidates.single.text} ${price.text}';
      consumed.add(price);
    }
  }
  final grouped = <MenuLine, MenuEntry>{};
  for (final title in lines) {
    final groupName = _groupName(title.text);
    if (groupName == null) continue;
    var bottom = (title.top + .23).clamp(0.0, 1.0);
    for (final next in lines) {
      if (next.page == title.page &&
          next.top > title.top + title.height &&
          next.left < .65 &&
          (_groupName(next.text) != null || _numbered(next.text))) {
        if (next.top < bottom) bottom = next.top;
      }
    }
    final options =
        lines
            .where(
              (l) =>
                  l.page == title.page &&
                  l.top >= title.top - title.height / 2 &&
                  l.top < bottom &&
                  l.left > title.left + title.width + .10 &&
                  _optionName(l.text) != null,
            )
            .toList()
          ..sort((a, b) => a.top.compareTo(b.top));
    if (options.isEmpty) continue;
    final details =
        lines
            .where(
              (l) =>
                  l != title &&
                  l.page == title.page &&
                  l.top > title.top + title.height &&
                  l.top < bottom &&
                  l.left < .68 &&
                  !_priceOnly(l.text) &&
                  !RegExp(r'^[A-Z]$').hasMatch(l.text),
            )
            .toList()
          ..sort((a, b) => a.top.compareTo(b.top));
    final variantPrices = <String, Set<String>>{};
    for (final option in options) {
      final name = _optionName(option.text)!;
      final prices = variantPrices.putIfAbsent(name, () => <String>{});
      for (final match in pricePattern.allMatches(
        paired[option] ?? option.text,
      )) {
        prices.add(
          match
              .group(0)!
              .replaceAll('＄', '\$')
              .replaceAll('﹩', '\$')
              .replaceAll(RegExp(r'\s'), ''),
        );
      }
    }
    final description = variantPrices.entries
        .map(
          (e) => e.value.length == 1
              ? '${e.key} ${e.value.single}'
              : '${e.key}價錢未能確認${e.value.length > 1 ? '，辨識有分歧，請重拍' : ''}',
        )
        .join('；');
    grouped[title] = MenuEntry(
      text: '$groupName。$description。${details.map((l) => l.text).join('。')}',
      section: groupName,
      page: title.page,
      uncertain: [title, ...options, ...details].any((l) => l.confidence < .5),
    );
    consumed.addAll([...options, ...details]);
  }
  final result = <MenuEntry>[];
  const known = {
    '早餐',
    '午餐',
    '下午茶',
    '晚餐',
    '飲品',
    '飲料',
    '小食',
    '套餐',
    '飯類',
    '麵類',
    '甜品',
    '主食',
    '飯餐',
    '粉麵',
    '熱飲',
    '凍飲',
  };
  final sections = <String, String>{};
  final multiColumn =
      lines.any((l) => l.left >= 0.5) &&
      lines.any((l) => l.left < 0.3 && l.width < 0.45);
  lines.sort((a, b) {
    final page = a.page.compareTo(b.page);
    if (page != 0) return page;
    if (multiColumn) {
      final col = (a.left >= 0.5 ? 1 : 0).compareTo(b.left >= 0.5 ? 1 : 0);
      if (col != 0) return col;
    }
    final y = a.top.compareTo(b.top);
    return y != 0 ? y : a.left.compareTo(b.left);
  });
  for (final line in lines) {
    if (consumed.contains(line)) continue;
    if (grouped.containsKey(line)) {
      result.add(grouped[line]!);
      continue;
    }
    final key = '${line.page}:${multiColumn && line.left >= 0.5 ? 1 : 0}';
    final clean = line.text.replaceAll(RegExp(r'[\s：:]'), '');
    if (known.contains(clean)) {
      sections[key] = clean;
      continue;
    }
    result.add(
      MenuEntry(
        text: paired[line] ?? line.text,
        section: _priceOnly(line.text) ? '未分類文字' : sections[key] ?? '未分類文字',
        page: line.page,
        uncertain: line.confidence < 0.5,
      ),
    );
  }
  return MenuDocument(
    entries: result,
    original: valid.map((l) => '第 ${l.page} 頁：${l.text}').join('\n'),
    diagnostics:
        'OCR 版本：$engineVersion\n配對版本：$menuParserVersion\n已配對價錢段數：${result.where((e) => e.prices.isNotEmpty && !_priceOnly(e.text)).length}\n原始文字段數：${valid.length}\n完整價錢標記：${lines.fold<int>(0, (n, l) => n + pricePattern.allMatches(l.text).length)}\n未帶貨幣符號的數字段數：${lines.where((l) => RegExp(r"^\d+(?:[.,]\d{1,2})?$").hasMatch(l.text.trim())).length}\n'
        '${valid.map((l) => "第 ${l.page} 頁 x=${l.left.toStringAsFixed(3)} y=${l.top.toStringAsFixed(3)} w=${l.width.toStringAsFixed(3)} h=${l.height.toStringAsFixed(3)}：${l.text}").join("\n")}',
    pages: pages,
    truncated: truncated,
    warnings: warnings,
  );
}

String? _optionName(String text) {
  final clean = normalizeMenuText(text);
  final match = RegExp(r'^(單拼|雙拼|三拼)').firstMatch(clean);
  return match?.group(1);
}

bool _numbered(String text) => RegExp(r'^\s*\d+[.．、，,]').hasMatch(text);
String? _groupName(String text) {
  final clean = normalizeMenuText(text).replaceFirst(RegExp(r'^[a-z]'), '');
  return switch (clean) {
    '三文治' => '三文治',
    '多士餐方包' => '多士餐／方包',
    _ => null,
  };
}

// Some spaced Chinese rows arrive as individual glyphs. Only join short glyph
// fragments on one baseline; full dish names remain separate to avoid guessing.
List<MenuLine> _joinMenuFragments(List<MenuLine> source) {
  final remaining = source.toList()..sort((a, b) => a.left.compareTo(b.left));
  final result = <MenuLine>[];
  while (remaining.isNotEmpty) {
    var current = remaining.removeAt(0);
    if (RegExp(r'^[\u3400-\u9fff]+$').hasMatch(current.text)) {
      final fragments = <MenuLine>[current];
      while (true) {
        final matches = remaining
            .where(
              (n) =>
                  n.page == current.page &&
                  RegExp(r'^[\u3400-\u9fff]+$').hasMatch(n.text) &&
                  (n.text.length <= 2 || current.text.length <= 2) &&
                  (n.top + n.height / 2 - current.top - current.height / 2)
                          .abs() <
                      current.height * .4 &&
                  n.left >= current.left + current.width - .005 &&
                  n.left - current.left - current.width < .025,
            )
            .toList();
        if (matches.isEmpty) break;
        final next = matches.first;
        fragments.add(next);
        remaining.remove(next);
        current = next;
      }
      if (fragments.length > 1) {
        final first = fragments.first;
        current = MenuLine(
          text: fragments.map((l) => l.text).join(),
          page: first.page,
          left: first.left,
          top: first.top,
          width: current.left + current.width - first.left,
          height: first.height,
          confidence: fragments
              .map((l) => l.confidence)
              .reduce((a, b) => a < b ? a : b),
        );
      }
    }
    result.add(current);
  }
  return result;
}

// Normalise numeric glyphs without changing OCR letters such as S/O into money.
String _priceCharacters(String text) => String.fromCharCodes(
  text.runes.map(
    (c) => c >= 0xff10 && c <= 0xff19
        ? c - 0xfee0
        : c == 0xff0e
        ? 0x2e
        : c,
  ),
);

List<MenuLine> _joinPriceFragments(List<MenuLine> lines) {
  final consumed = <MenuLine>{};
  final joined = <MenuLine>[];
  final currency = RegExp(r'^(?:HK\s*)?[\$＄﹩]$', caseSensitive: false);
  final number = RegExp(r'^\d{1,4}(?:[.,]\d{1,2})?$');
  bool adjacent(MenuLine symbol, MenuLine value) =>
      symbol.page == value.page &&
      value.left >= symbol.left + symbol.width - .005 &&
      value.left - symbol.left - symbol.width <= .035 &&
      (value.top + value.height / 2 - symbol.top - symbol.height / 2).abs() <=
          (value.height > symbol.height ? value.height : symbol.height) * .6;
  for (final symbol in lines.where((l) => currency.hasMatch(l.text.trim()))) {
    final candidates = lines
        .where(
          (l) =>
              !consumed.contains(l) &&
              number.hasMatch(l.text.trim()) &&
              adjacent(symbol, l),
        )
        .toList();
    if (candidates.length != 1) continue;
    final value = candidates.single;
    // Two possible symbols for one amount are also ambiguous.
    if (lines
            .where(
              (s) => currency.hasMatch(s.text.trim()) && adjacent(s, value),
            )
            .length !=
        1) {
      continue;
    }
    consumed.addAll([symbol, value]);
    final top = symbol.top < value.top ? symbol.top : value.top;
    final bottom = symbol.top + symbol.height > value.top + value.height
        ? symbol.top + symbol.height
        : value.top + value.height;
    joined.add(
      MenuLine(
        text: '${symbol.text.trim()}${value.text.trim()}',
        page: symbol.page,
        left: symbol.left,
        top: top,
        width: value.left + value.width - symbol.left,
        height: bottom - top,
        confidence: symbol.confidence < value.confidence
            ? symbol.confidence
            : value.confidence,
      ),
    );
  }
  return [...lines.where((l) => !consumed.contains(l)), ...joined];
}

// Multi-pass OCR can return both a complete line and the glyphs inside it.
// Remove only geometry-covered readings whose text is actually contained;
// conflicting text remains available for ambiguity handling and raw diagnostics.
List<MenuLine> _removeCoveredMenuFragments(List<MenuLine> lines) {
  double area(MenuLine l) => l.width * l.height;
  double overlap(MenuLine a, MenuLine b) {
    final left = a.left > b.left ? a.left : b.left;
    final top = a.top > b.top ? a.top : b.top;
    final right = a.left + a.width < b.left + b.width
        ? a.left + a.width
        : b.left + b.width;
    final bottom = a.top + a.height < b.top + b.height
        ? a.top + a.height
        : b.top + b.height;
    return right > left && bottom > top ? (right - left) * (bottom - top) : 0;
  }

  return lines
      .where(
        (small) => !lines.any((large) {
          if (identical(small, large) ||
              small.page != large.page ||
              large.height > small.height * 2 ||
              small.height > large.height * 2) {
            return false;
          }
          final a = normalizeMenuText(small.text),
              b = normalizeMenuText(large.text);
          final smallPrices = pricePattern
              .allMatches(small.text)
              .map((m) => normalizeMenuText(m.group(0)!))
              .toSet();
          final largePrices = pricePattern
              .allMatches(large.text)
              .map((m) => normalizeMenuText(m.group(0)!))
              .toSet();
          if (!largePrices.containsAll(smallPrices)) {
            return false;
          }
          if (a.isEmpty ||
              !b.contains(a) ||
              overlap(small, large) / area(small) < .65) {
            return false;
          }
          if (a == b) {
            // Stable tie breaking retains one duplicate, not zero.
            return area(large) > area(small) * 1.01 ||
                ((area(large) - area(small)).abs() <= area(small) * .01 &&
                    lines.indexOf(large) < lines.indexOf(small));
          }
          return large.width > small.width * 1.25;
        }),
      )
      .toList();
}

// Infer repeated price columns, instead of assuming every menu has two columns.
// At least three distinct rows establish a column; a single shared/bracketed
// price cannot create a boundary. The raw OCR remains unchanged.
Map<int, List<List<MenuLine>>> _menuPriceColumns(List<MenuLine> lines) {
  final result = <int, List<List<MenuLine>>>{};
  for (final page in lines.map((l) => l.page).toSet()) {
    final amounts =
        lines.where((l) => l.page == page && _priceOnly(l.text)).toList()..sort(
          (a, b) => (a.left + a.width / 2).compareTo(b.left + b.width / 2),
        );
    final groups = <List<MenuLine>>[];
    for (final value in amounts) {
      final centre = value.left + value.width / 2;
      if (groups.isEmpty ||
          (centre - groups.last.first.left - groups.last.first.width / 2)
                  .abs() >
              .085) {
        groups.add([value]);
      } else {
        groups.last.add(value);
      }
    }
    result[page] = groups
        .where((g) => g.map((l) => (l.top * 500).round()).toSet().length >= 3)
        .toList();
  }
  return result;
}

bool _samePriceColumn(
  MenuLine text,
  MenuLine price,
  List<List<MenuLine>> columns,
) {
  if (columns.length < 2) return true;
  for (final prior in columns) {
    final centre =
        prior.map((l) => l.left + l.width / 2).reduce((a, b) => a + b) /
        prior.length;
    if (price.left - centre > .10) {
      final boundary = prior
          .map((l) => l.left + l.width)
          .reduce((a, b) => a > b ? a : b);
      if (text.left < boundary - .01) return false;
    }
  }
  return true;
}
