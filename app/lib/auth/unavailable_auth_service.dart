/// **沒有後端時的登入服務：一個誠實的「尚未提供」stub。**
///
/// ## 這個檔案為什麼存在
///
/// Spec 1 **沒有後端**：沒有帳號伺服器、沒有 OAuth 憑證、沒有任何端點。
/// 「登入」這件事現在**做不到**。做不到的服務只有一種誠實的回應方式：
/// **不要宣稱成功，也不要假裝自己已經登入**。
///
/// ## ★ 它永遠不會回報成功
///
/// 正式入口（`main.dart` → `HomePage`）以前接的是 `MockAuthService`。
/// 那是一個假貨，而假貨的**預設**結果是
/// `SignedIn(MockAuthService.defaultAccount)`——`mock.user@pathguide.test`
/// ／`Mock User`。於是正式 App 會**偽造一次成功的登入**：
/// `auth_page.dart` 播報「登入成功」並返回，設定頁的帳號列顯示「已登入」。
///
/// 對看不見的使用者，這是關於**安全狀態**的謊言：他會相信自己登入了、
/// 相信未識別障礙物真的上傳了、相信資料真的同步到伺服器——而那些能力
/// 一個都不存在。**誠實的訪客狀態永遠比假的已登入狀態好。**
///
/// 這個實作因此只有一條規則：
/// **任何會產生登入狀態的方法都回 `AuthFailed`，沒有任何路徑回 `SignedIn`。**
///
/// ## 使用者實際聽到什麼
///
/// `AuthFailed` 只帶 `AuthProblem`（刻意：sealed 型別逼畫面把每一種問題
/// 翻成一句播報加一個出口，服務層不該塞自由文字），而 `AuthProblem` 裡
/// **沒有**「服務尚未提供」這一種，所以畫面會落到通用錯誤那一支：
///
/// - 播報（≤ 12 字）：「登入沒成功」
/// - 畫面長句：「登入沒有成功，請再試一次。」
///
/// ★ 這不是理想的文案（「請再試一次」在這裡是無效的建議）。兩件事讓它
/// 仍然可以接受：
///
/// 1. [availableProviders] 回**空集合**，而 `auth_page.dart` 只畫
///    `availableProviders()` 裡有的方式——**帳號頁連一顆按了也不會成功的
///    登入按鈕都不會畫**，所以使用者正常走不到上面那一句。
/// 2. 留著 `AuthFailed` 是給「有人把按鈕加回來」那天的最後一道防線：
///    寧可說「登入沒成功」，也絕不可以說「登入成功」。
///
/// 要換成「登入功能還沒提供，可以先選稍後再說」需要新的 `AuthProblem`
/// 值或一句自由文字，那會動到 `auth_service.dart`／`auth_strings.dart`／
/// `auth_page.dart` 三個檔案的契約，不是本輪的範圍。
///
/// ## 什麼時候刪掉它
///
/// 真正的 `AuthService`（接上後端）落地、並改名之後的那一天。
/// `mock_auth_service.dart` **不要**跟著刪：它的用途是測試——它可以
/// 「故意失敗」，那是「載入中／離線／取消／需要連結」這些分支唯一的
/// 測試來源（見該檔檔頭）。它只是**不可以**再被正式入口使用。
library;

import 'auth_service.dart';

/// 沒有後端時的登入服務。**唯讀的訪客狀態，並且永不回報成功。**
///
/// 見本檔檔頭：它存在是因為 Spec 1 沒有後端，而且正式 App 不可以偽造
/// 一次登入。真正的實作落地後，這整個檔案應該被換掉。
final class UnavailableAuthService implements AuthService {
  const UnavailableAuthService();

  /// 每個「要登入才會發生」的方法都回這**同一個**結果。
  ///
  /// 用 `AuthProblem.unknown` 而不是 `network`／`providerUnavailable`：
  /// 那兩個會被翻成「連不上網路」「這台手機沒設定指紋，可以改用 Google」，
  /// 兩句都是**具體但不實的原因**，還會把使用者導向一個不存在的方法。
  /// `unknown` 對應的通用句至少不宣稱任何原因、也不宣稱任何成功。
  static const AuthFailed notAvailable = AuthFailed(AuthProblem.unknown);

  /// 一個登入方式都沒有。
  ///
  /// ★ 空集合不只是「沒東西顯示」，它是誠實的來源：帳號頁只畫
  /// `availableProviders()` 裡有的方式，所以空集合等於
  /// **畫面上不會出現按了也不會成功的按鈕**（那對全盲使用者是純粹的陷阱）。
  @override
  Future<Set<AuthProvider>> availableProviders() async => const <AuthProvider>{};

  /// 沒有存過任何帳號，所以一定是訪客。
  ///
  /// 設定頁因此照實說「訪客（可完整使用識別）」，而不是「已登入」。
  @override
  Future<AuthAccount?> restore() async => null;

  @override
  Future<AuthResult> signIn(AuthProvider provider) async => notAvailable;

  @override
  Future<AuthResult> requestEmailCode(String email) async => notAvailable;

  @override
  Future<AuthResult> verifyEmailCode(String email, String code) async =>
      notAvailable;

  @override
  Future<AuthResult> linkProvider(AuthProvider provider) async => notAvailable;

  @override
  Future<AuthResult> unlinkProvider(AuthProvider provider) async =>
      notAvailable;

  /// 沒有東西可以登出（本來就是訪客），所以什麼都不做。
  ///
  /// 刻意**不拋例外**：帳號頁的「登出」是按得到的，拋出去等於按下按鈕後
  /// 沒有任何聲音——那正是這一整條工作線在修的那類缺陷。
  @override
  Future<void> signOut() async {}

  /// 沒有帳號可以刪，所以什麼都不做。理由同 [signOut]。
  @override
  Future<void> deleteAccount() async {}
}
