import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import '../vision/labels.dart';
import 'english.dart';

String appText(String text, AppLanguage language) {
  if (language == AppLanguage.chinese) return text;
  final exact = english[text];
  if (exact != null) return exact;
  for (final label in kLabels) {
    if (text == label.nameZh) return label.nameEn.replaceAll('_', ' ');
  }
  if (text.contains('、')) {
    final labels = text.split('、');
    if (labels.every(
      (value) => kLabels.any((label) => label.nameZh == value),
    )) {
      return labels.map((value) => appText(value, language)).join(', ');
    }
  }
  for (final entry in englishTemplates.entries) {
    final parts = entry.key.split('{}');
    final pattern = '^${parts.map(RegExp.escape).join('(.*?)')}\$';
    final match = RegExp(pattern, dotAll: true).firstMatch(text);
    if (match == null) continue;
    var index = 0;
    return entry.value.replaceAllMapped(
      RegExp(r'\{\}'),
      (_) => appText(match.group(++index)!, language),
    );
  }
  // User data and native/provider diagnostics retain their original wording.
  return text;
}

extension AppTranslation on BuildContext {
  AppLanguage get appLanguage =>
      dependOnInheritedWidgetOfExactType<AppLanguageScope>()?.language ??
      AppLanguage.chinese;
  String tr(String text) => appText(text, appLanguage);
}

class AppLanguageScope extends InheritedWidget {
  const AppLanguageScope({
    super.key,
    required this.language,
    required super.child,
  });
  final AppLanguage language;
  @override
  bool updateShouldNotify(AppLanguageScope oldWidget) =>
      language != oldWidget.language;
}

/// Localizes product copy while keeping const call sites and text scaling.
/// Provider and user content should use the normal Text widget.
class AppText extends StatelessWidget {
  const AppText(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
    this.semanticsLabel,
    this.textScaler,
    this.textDirection,
    this.strutStyle,
    this.textWidthBasis,
    this.textHeightBehavior,
  });
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;
  final String? semanticsLabel;
  final TextScaler? textScaler;
  final TextDirection? textDirection;
  final StrutStyle? strutStyle;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  @override
  Widget build(BuildContext context) => Text(
    context.tr(data),
    style: style,
    textAlign: textAlign,
    maxLines: maxLines,
    overflow: overflow,
    softWrap: softWrap,
    textScaler: textScaler,
    textDirection: textDirection,
    strutStyle: strutStyle,
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
    semanticsLabel: semanticsLabel == null ? null : context.tr(semanticsLabel!),
  );
}
