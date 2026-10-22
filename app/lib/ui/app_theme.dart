import 'package:flutter/material.dart';

/// 全 App 的顏色 token。以前 `0xFF0B0F13` 這類字面量散在三個檔案裡，
/// 改一次配色要追三處；集中之後只改這裡。
///
/// 為什麼是深色：室外強光下深色底更省電也更好讀（沿用 `main.dart` 的既有決定）。
abstract final class AppColors {
  /// 頁面底色。
  static const Color background = Color(0xFF0B0F13);

  /// 卡片／底部動作區。
  static const Color surface = Color(0xFF161B22);

  /// 主要文字。
  static const Color onSurface = Color(0xFFFFFFFF);

  /// 次要文字（狀態句、說明）。
  static const Color onSurfaceMuted = Color(0xB3FFFFFF);

  /// 強調色。種子色 `#2E7D32` 在深色 theme 下的亮階。
  static const Color accent = Color(0xFF81C784);
}
