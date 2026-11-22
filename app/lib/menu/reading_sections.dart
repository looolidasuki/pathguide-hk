import 'menu_document.dart';

/// Keeps OCR regions separate. A horizontal gap between overlapping rows
/// suggests columns, but is not enough to certify their reading order.
({List<MenuLine> lines, bool uncertainOrder}) readingSections(
  List<MenuLine> source,
) {
  final pages = <int, List<MenuLine>>{};
  for (final line in source) {
    if (line.text.trim().isEmpty) continue;
    (pages[line.page] ??= []).add(line);
  }
  final lines = <MenuLine>[];
  var uncertain = false;
  for (final page in pages.keys.toList()..sort()) {
    final rows = pages[page]!
      ..sort((a, b) {
        final vertical = a.top.compareTo(b.top);
        return vertical == 0 ? a.left.compareTo(b.left) : vertical;
      });
    double? split;
    for (final a in rows) {
      for (final b in rows) {
        if (a.left + a.width + .04 < b.left &&
            a.top < b.top + b.height &&
            b.top < a.top + a.height) {
          split = (a.left + a.width + b.left) / 2;
          break;
        }
      }
      if (split != null) break;
    }
    if (split == null) {
      lines.addAll(rows);
    } else {
      uncertain = true;
      final boundary = split;
      lines.addAll(rows.where((line) => line.left + line.width <= boundary));
      lines.addAll(rows.where((line) => line.left >= boundary));
      lines.addAll(
        rows.where(
          (line) => line.left < boundary && line.left + line.width > boundary,
        ),
      );
    }
  }
  return (lines: lines, uncertainOrder: uncertain);
}
