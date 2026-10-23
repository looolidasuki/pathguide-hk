import '../l10n/app_strings.dart';

/// 需要登入與網路的雲能力。**核心識別不在此列**（spec §1.1）。
///
/// 這裡刻意不列「引導」「讀字」「播報」：那三件事是離線的核心能力，
/// 任何門禁都不得擋（Global Constraints 第一條）。
enum CloudCapability { uploadFrames, syncSettings, visionQuery, planRoute }

/// 只有兩態：訪客或已登入。
///
/// 為什麼沒有「半登入」：那種狀態沒有人測得完，而這裡判斷錯的代價是
/// 「盲人在街上以為功能可用」。
enum SessionState { guest, authenticated }

/// 雲能力門禁：狀態兩態 ＋ 一個離線修飾位。
///
/// 只有 `authenticated && isOnline` 才放行。刻意做成 `const` 可建的純值物件，
/// 呼叫方（UI、上傳隊列）不必持有可變狀態就能問「現在能不能用」。
class FeatureGate {
  const FeatureGate({required this.state, required this.isOnline});

  final SessionState state;
  final bool isOnline;

  /// `capability` 目前不影響判斷：四項雲能力的前置條件完全相同（登入＋有網）。
  /// 保留參數是為了將來某項能力放寬（例如 `syncSettings` 允許離線寫本機）時，
  /// 呼叫方不用改。
  bool allows(CloudCapability capability) =>
      state == SessionState.authenticated && isOnline;

  /// 給 TTS／畫面用的**可操作**說明：不是「無權限」，而是「怎麼才能用」。
  ///
  /// 訪客 → 說「需要登入」；已登入但離線 → 說「沒有網絡」。
  /// 兩句都附帶「識別不受影響」，避免使用者以為 App 壞了。
  String denialMessage(CloudCapability capability) {
    final s = AppStrings.current;
    if (state == SessionState.guest) {
      return s.deniedNeedsLogin;
    }
    return s.deniedNeedsNetwork;
  }
}
