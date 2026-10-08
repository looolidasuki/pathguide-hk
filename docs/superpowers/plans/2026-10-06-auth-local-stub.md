# 登入功能的本地 stub 設計

日期：2026-10-06
前置文件：`docs/A11Y-ENTRY-AND-AUTH.md`（無障礙規範與驗收清單）

## 0. 這一步要解決什麼

做一個**不需要任何後端、不需要任何帳號**的登入功能，把最難的部分先做完並用測試釘死。

最難的部分不是「連上 Google」，是**盲人能不能自己走完登入流程而不迷路、不卡死**。
這件事跟用哪個後端完全無關：語意標籤、焦點順序、錯誤播報、逾時處理、按鈕文案，
換成任何後端都一模一樣。後端是最後 10%。

## 1. 先講清楚「stub」是什麼（給新手）

**stub 就是一個假貨**：它長得跟真的一模一樣（同一組方法），但裡面不連網路，
直接回傳預先寫好的結果。

為什麼要這樣做：

1. **可以立刻開工**。真的 Google 登入需要 Google Cloud 專案、OAuth 同意畫面、
   SHA-1 指紋，這些都要你手動去點。stub 不需要。
2. **可以測試錯誤情況**。這一點是關鍵，下面第 3 節會展開講。
3. **換後端時只換一個檔案**。介面不變、畫面不變、測試不變，
   只有「實作」那一層換掉。

**這個專案本來就是這樣做的。** `app/lib/vision/mock_vision_source.dart` 就是相機的假貨，
它讓整個畫面與測試可以在沒有相機的情況下跑起來。登入照同一套路走，
不是新發明。

## 2. 檔案規劃（全部是新檔，不碰別人的檔案）

```
app/lib/auth/
  auth_service.dart        介面 + 資料模型 + 結果型別
  mock_auth_service.dart   假實作（可腳本化失敗）
  session_store.dart       「記住我」的儲存介面 + 記憶體版
  auth_strings.dart        登入頁文案（英文預設 + 繁體中文）
app/lib/ui/
  auth_page.dart           登入頁
app/test/
  auth_service_test.dart           介面與假實作的單元測試
  auth_page_semantics_test.dart    語意樹與焦點順序
  auth_page_states_test.dart       載入／錯誤／取消／逾時
```

**★ 零新依賴。** 全部是純 Dart + Flutter，不動 `pubspec.yaml`。
這代表**零建構風險**（`app/pubspec.yaml` 裡那條「路徑含空格 + objective_c」的硬約束碰不到）。

**為什麼文案獨立成 `auth_strings.dart`**：`app/lib/l10n/app_strings.dart` 不在我的範圍內，
硬去改會跟另一邊的工作衝突。所以先用同樣的寫法（`_zh` 分支、英文預設）獨立一份，
之後合併。這是暫時的技術債，要記在 `docs/PROJECT-STATUS.md` 的風險表裡。

## 3. 介面設計

### 3.1 結果型別：用 sealed class，不用例外

```dart
sealed class AuthResult {
  const AuthResult();
}

/// 成功。帶著帳號資料回來。
final class SignedIn extends AuthResult {
  const SignedIn(this.account);
  final AuthAccount account;
}

/// 使用者自己取消（按了返回、關掉 Google 的畫面）。
/// ★ 這不是錯誤，不可以報錯。
final class AuthCancelled extends AuthResult {
  const AuthCancelled();
}

/// 失敗。problem 決定要播報哪一句。
final class AuthFailed extends AuthResult {
  const AuthFailed(this.problem);
  final AuthProblem problem;
}

/// 這個電子郵件已經用別的方式註冊過，需要使用者決定要不要綁定。
final class NeedsLinking extends AuthResult {
  const NeedsLinking({required this.email, required this.existing});
  final String email;
  final AuthProvider existing;
}

enum AuthProblem {
  network,            // 連不上
  providerUnavailable, // 手機沒設指紋、Play 服務缺失、iOS 沒登入 Apple 帳號
  accountLocked,      // 帳號被鎖
  rejected,           // 伺服器明確拒絕
  unknown,
}
```

**為什麼用 `sealed` 而不是丟例外？**（新手重點）

`sealed` 是 Dart 3 的語法，意思是「這組型別就這幾個，不會有別的」。
於是寫 `switch` 的時候，**編譯器會強制你處理每一個分支**，少寫一個就編譯不過。

這件事對盲人使用者特別重要：如果漏掉一個錯誤分支，結果就是
**使用者按下按鈕之後，畫面沒有任何反應，也沒有任何聲音**。他看不到轉圈圈，
所以會以為程式壞了，然後一直重複按。用例外處理錯誤的話，
漏掉一個 `catch` 只有執行到才會發現；用 `sealed` 的話，寫錯的當下就編譯不過。

**預期的結果不要用例外。** 「使用者取消」是完全正常的事，不是異常狀況。
把它當例外會讓每一層都要寫 `try/catch`，而且很容易漏。

### 3.2 介面

```dart
abstract interface class AuthService {
  /// 這台裝置現在能用哪些登入方式。
  /// 例如手機沒設指紋就不該顯示密鑰選項，不是顯示了再失敗。
  Future<Set<AuthProvider>> availableProviders();

  /// 已經登入過就直接拿回帳號（「記住我」的讀取端）。
  Future<AuthAccount?> restore();

  Future<AuthResult> signIn(AuthProvider provider);

  /// 電子郵件一次性驗證碼：分成「寄出」與「驗證」兩步。
  Future<AuthResult> requestEmailCode(String email);
  Future<AuthResult> verifyEmailCode(String email, String code);

  /// 帳號綁定（一個帳號掛多個登入方式）。
  Future<AuthResult> linkProvider(AuthProvider provider);
  Future<AuthResult> unlinkProvider(AuthProvider provider);

  Future<void> signOut();

  /// 刪除帳號。應用程式內必須可用，不能要求聯絡客服。
  Future<void> deleteAccount();
}
```

**`availableProviders()` 的設計理由**：無障礙規範第 4.1 節的順位是
「密鑰 → Google → Apple → 電子郵件」。但如果手機根本沒設指紋，
顯示一個註定失敗的密鑰按鈕，對盲人使用者是純粹的陷阱（他按了、被拒、不知道為什麼）。
**可用的東西才顯示**，這是「不要給死路」原則的具體落實。

## 4. 假實作：必須能「故意失敗」

```dart
class MockAuthService implements AuthService {
  MockAuthService({
    this.delay = Duration.zero,
    Set<AuthProvider>? available,
    List<AuthResult>? scripted,
  });

  /// 依序吐出預先排好的結果；用完了就回傳預設成功。
  final List<AuthResult> _queue;

  /// 每次呼叫的紀錄，讓測試可以斷言「按一次只呼叫一次」。
  final List<String> calls = [];
}
```

**★ 這是整個設計最重要的一點：假實作一定要能產生失敗。**

如果假實作永遠成功，那麼「載入中」「網路錯誤」「使用者取消」「帳號已存在」
這些分支**永遠不會被執行到**，也就永遠不會被測試到。而這些正是盲人使用者
真正會卡住的地方。永遠成功的假實作，等於沒有測試。

所以提供幾個現成的建構子：

| 建構子 | 用途 |
|---|---|
| `MockAuthService.offline()` | 每次都回 `AuthFailed(network)` |
| `MockAuthService.slow()` | 延遲 3 秒才回，用來測「按下後必須立刻有聲音」 |
| `MockAuthService.biometricMissing()` | 沒有密鑰可用 |
| `MockAuthService.needsLinking(email)` | 回 `NeedsLinking` |
| `MockAuthService.cancelled()` | 回 `AuthCancelled` |

## 5. 儲存層：為什麼要切一個介面出來

「記住我」需要把帳號寫到磁碟上。但**磁碟套件的選擇現在還不能決定**，
因為 `app/pubspec.yaml` 有一條硬約束：任何拉進 `objective_c` 的依賴都會讓建構失敗
（倉庫路徑含空格），而這只能用真的一次建構來驗證。

所以我切一個介面：

```dart
abstract interface class SessionStore {
  Future<AuthAccount?> read();
  Future<void> write(AuthAccount? account);
}

/// 記憶體版：App 一關就忘。stub 階段用這個。
class InMemorySessionStore implements SessionStore { ... }
```

於是 UI 與測試現在就能做完，真正的磁碟版之後補（大約 15 行），
而且換的時候不會動到任何畫面或測試。

## 6. 畫面：語意與焦點順序

結構照 `docs/A11Y-ENTRY-AND-AUTH.md` 第 4.3 節。實作上有四個技術要點。

### 6.1 焦點順序要釘死

```dart
FocusTraversalGroup(
  policy: OrderedTraversalPolicy(),
  child: Column(children: [
    FocusTraversalOrder(order: const NumericFocusOrder(1), child: _heading()),
    FocusTraversalOrder(order: const NumericFocusOrder(2), child: _googleButton()),
    // ...
  ]),
)
```

**為什麼不能靠 widget 樹的順序**：Flutter 的預設焦點順序跟著 widget 樹走，
但 widget 樹會因為版面需求被調整（例如為了對齊多包一層 `Padding`）。
一旦有人重構版面，朗讀順序就會跟著亂，而且**沒有任何錯誤訊息**。
用 `NumericFocusOrder` 明示順序，重構就不會弄壞它。

### 6.2 按鈕標籤必須是「動作 + 結果」

| ❌ | ✅ |
|---|---|
| `Google` | `用 Google 帳號登入` |
| `確定` | `確認並登入` |

圖示與品牌色對全盲使用者沒有資訊量，**標籤是唯一的語意來源**。
用 `MergeSemantics` 把「圖示 + 文字」合併成一個焦點，否則會被唸兩次。

### 6.3 載入與錯誤一定要「主動」播報

```dart
Semantics(
  liveRegion: true,
  child: Text(_statusText),
)
```

`liveRegion: true` 的意思是「這段文字變了要主動唸出來」，不需要使用者去摸到它。
沒有這個，盲人使用者按下按鈕後只會聽到一片安靜。

### 6.4 ★ 一個需要決定的問題：誰來出聲？

這裡有個真實的衝突：**TalkBack 開著的時候，它自己就會唸出焦點元素。
如果我們的 App 又用自己的 TTS 唸一次，就會兩隻聲音疊在一起。**

我的建議是**看情形**：

```dart
final screenReaderOn = MediaQuery.of(context).accessibleNavigation;
```

| `accessibleNavigation` | 誰出聲 |
|---|---|
| `true`（TalkBack/VoiceOver 開著） | 交給螢幕閲讀器。我們只用 `liveRegion` 補「狀態變化」 |
| `false`（沒有螢幕閲讀器） | 用 App 自己的 TTS（`Speaker` 介面），因為沒有人會幫我們唸 |

`MediaQuery.accessibleNavigation` 是 Flutter 對「系統無障礙導覽是否開啟」的判斷。

⚠️ **這一條我沒有在真機上驗證過**，`accessibleNavigation` 在 Android 上
是否能準確反映 TalkBack 狀態，需要在你的手機上實測一次（開／關 TalkBack 各一次）。
**不要因為它在文件裡看起來對就直接採用。**

## 7. 測試策略

### 7.1 要測什麼

| 測試檔案 | 斷言 |
|---|---|
| `auth_service_test.dart` | 假實作本身的行為（腳本用完後回什麼、呼叫紀錄） |
| `auth_page_semantics_test.dart` | 每個可互動元素都有標籤；標籤是動作+結果；焦點順序等於朗讀順序 |
| `auth_page_states_test.dart` | 載入、四種錯誤、取消、逾時、`NeedsLinking` 各自的行為 |

### 7.2 怎麼測語意（新手重點：這不是空談）

Flutter 有現成的工具，不是靠人工看：

```dart
final handle = tester.ensureSemantics();          // 打開語意樹
expect(tester.getSemantics(find.byKey(kGoogleButton)),
       matchesSemantics(label: '用 Google 帳號登入', isButton: true, hasTapAction: true));
handle.dispose();
```

`ensureSemantics()` 是必要的，否則測試環境裡語意樹是關的，
`getSemantics` 會拿不到東西（這是最常見的踩坑點）。

焦點順序用 `tester.sendKeyEvent(LogicalKeyboardKey.tab)` 逐次按，
斷言取得焦點的順序與預期一致。

### 7.3 ★ 一個容易被忽略的測試：測「假貨」本身

如果假實作寫錯了（例如腳本用完後偷偷回成功），
上面所有測試都會**因為錯的理由而通過**。所以 `auth_service_test.dart`
要單獨驗證假實作：餵三個腳本進去，斷言第四次呼叫的行為。

### 7.4 三個最關鍵的斷言

這三條如果沒有，這個登入頁就沒有達到目的：

1. **「按下後立刻有回饋」**：用 `MockAuthService.slow()`（延遲 3 秒），
   斷言在延遲結束**之前**就已經產生了一次播報。
   沒有這條，「按了沒反應」的 bug 會在真實網路上出現。
2. **「『稍後再説』可用且不擋路」**：斷言取消後回傳未登入狀態，
   且引導畫面仍然可以進入。
3. **「每個錯誤都有出口」**：對每個 `AuthProblem` 斷言畫面上存在
   一個可重試或可離開的元素。沒有這條，某個錯誤會變成死路。

## 8. 要怎麼接進現有 App（最小侵入）

**登入頁不是首頁。** 引導功能是首頁，登入是從「帳號」或「上傳」進去的獨立頁面
（見 `docs/A11Y-ENTRY-AND-AUTH.md` 第 1 節：登入不得擋路）。

stub 階段**先不改 `main.dart`**（那是別人的檔案）。做法是提供一個
可以直接 push 的 `AuthPage`，整合留到最後一步、用一個呼叫點完成。

**情境式提示**（設計，暫不實作）：使用者在未登入時按「上傳」，
彈出一個説明「登入可以做什麼」，兩個同級選擇：「登入」與「先不用」。
因為上傳功能還沒做，這一項現在只是設計。

## 9. 工作順序（每一步都能單獨驗證）

| 步 | 做什麼 | 怎麼驗證 | 預估 |
|---|---|---|---|
| 1 | `auth_service.dart`（介面 + 模型 + 結果型別） | 編譯通過；`switch` 窮盡性由編譯器檢查 | 小 |
| 2 | `mock_auth_service.dart` + `auth_service_test.dart` | `flutter test` | 小 |
| 3 | `session_store.dart`（介面 + 記憶體版） | `flutter test` | 很小 |
| 4 | `auth_strings.dart`（英文預設 + 繁體中文） | 對照 `app_strings.dart` 的既有寫法 | 小 |
| 5 | `auth_page.dart` 靜態版（只有版面與語意，沒有邏輯） | 語意測試 | 中 |
| 6 | 接上邏輯：載入、錯誤、取消、逾時、綁定 | 狀態測試 | 中 |
| 7 | 整合到 App（一個呼叫點） | 真機 + TalkBack | 小 |

**第 1 到 6 步完全不依賴你的帳號、後端、網路。**

## 10. 這個 stub 做不到什麼（誠實説明）

- **不能真的登入**。沒有帳號、沒有權杖、沒有伺服器往返。
- **不能證明真的 OAuth 流程會動**。那取決於 Google Cloud 的設定與 SHA-1 指紋，
  與程式碼品質無關。
- **介面之後可能要改**。Apple 的「隱藏我的電子郵件」需要多一個欄位；
  通行密鑰的 challenge 流程可能需要非同步的兩段式介面。
  所以「換後端只換一個檔案」是**大致成立，不是零返工**。

## 11. 建構風險

**零新依賴 = 零建構風險**，這是選擇 stub 的附帶好處。

但要注意：**跑 `flutter test` 需要放寬沙箱權限**（目前受限模式會擋住 Flutter/Dart）。
這是一次性的授權，不是每次都要。
