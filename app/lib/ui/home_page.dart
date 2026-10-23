import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../auth/unavailable_auth_service.dart';
import '../l10n/app_strings.dart';
import '../settings/app_settings.dart';
import '../vision/vision_session.dart';
import 'auth_page.dart';
import 'read_text_page.dart';
import 'demo_page.dart';
import 'settings_page.dart';

/// 主界面：**選一個模式**。
///
/// ## 為什麼要分成兩個模式（這是真機證據推出來的，不是偏好）
///
/// 引導與讀字會互搶，而且兩邊都因此變差：
///
/// - **CPU**：讀字一次 0.6–2.0 秒（1280×960），偵測一次 197 ms。
///   同時跑時讀字只能擠在偵測空檔。
/// - **語音**：真機實測招牌有**一半**被障礙物播報讓位丟掉（`spotDeferred` 12/22），
///   而且永遠不會補唸。
///
/// 兩顆按鈕讓使用者明確表達「我現在要哪一件事」，程式才知道該把
/// CPU 與語音優先給誰。
///
/// ## 無障礙考量
///
/// - **三個可操作項，主模式在前**：從 App 啟動到「開始引導」仍是
///   1 次焦點移動 + 雙擊（驗收清單要求 ≤ 4 次）。設定排在**最後**，
///   而且是次級形狀（`OutlinedButton`），所以它不會擋在「開始引導」前面，
///   也不會被誤當成第三個主模式。
/// - **標籤就是結果**：不用「模式一」「選項 A」這類要記憶的詞。
/// - **按鈕加大**（100% 字級下每個至少 72 高）：低視力使用者的觸控精確度
///   通常較差，而這是全 App 最常按的兩個東西。72／48 都只是**下限**
///   （`minHeight`），200% 字級時按鈕會自己長高，不會把說明切掉。
/// - 每個模式都有一句說明，**進入後也會再播報一次**自己在哪裡。
/// - 整頁可以捲：200% 字級 + 窄機時三個入口比螢幕高，不捲就等於把
///   「設定」（最後一站）直接裁掉。
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.session,
    this.settings,
    this.authService,
  });

  /// 相機與語音的共用持有者。預設自己建一個；測試注入假的。
  final VisionSession? session;

  /// 使用者設定。沒注入就建一個純記憶體的（測試、或直接開這一頁時）。
  final AppSettings? settings;

  /// 帳號狀態的來源。沒注入就建一個**誠實的「尚未提供」stub**
  /// （[UnavailableAuthService]，見 [_authService]）。
  final AuthService? authService;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final VisionSession _session = widget.session ?? VisionSession();
  late final AppSettings _settings = widget.settings ?? AppSettings.memory();

  /// 帳號服務。**預設是「沒有後端」的誠實 stub**（[UnavailableAuthService]）。
  ///
  /// ★ 這裡以前接的是 `MockAuthService`，那是一個**會偽造成功**的假貨：
  /// 它的預設結果是 `SignedIn` 帶一個假帳號（`mock.user@pathguide.test`／
  /// `Mock User`），於是**正式 App 會假裝登入成功**——帳號頁播報
  /// 「登入成功」並返回，設定頁的帳號列顯示「已登入」。
  ///
  /// 對看不見的使用者，這是關於**安全狀態**的謊言：他會相信自己登入了、
  /// 以為上傳與同步真的送到伺服器，而那些能力一個都不存在（Spec 1 沒有
  /// 後端）。誠實的訪客狀態永遠勝過假的已登入狀態。
  ///
  /// [UnavailableAuthService] 反過來做三件誠實的事：
  /// `restore()` 回 `null`（設定頁照實說「訪客（可完整使用識別）」）、
  /// `availableProviders()` 回空集合（帳號頁**不畫**任何一顆按了也不會成功的
  /// 登入按鈕）、所有會產生登入狀態的方法都回 `AuthFailed`（永不 `SignedIn`）。
  ///
  /// `MockAuthService` **沒有被刪**：它是測試的來源（它可以「故意失敗」，
  /// 讓離線／取消／需要連結這些分支真的被執行到）。它只是不可以再被
  /// 正式入口使用。
  ///
  /// ⚠️ **後端就緒後把這一行換成真正的 `AuthService` 實現**（`HttpApi` 的
  /// 登入端點），設定頁與帳號頁一行都不用改。
  late final AuthService _authService =
      widget.authService ?? const UnavailableAuthService();

  /// 自己建的設定才由自己釋放；`main` 注入的那份比這一頁活得久，不能動。
  bool get _ownsSettings => widget.settings == null;

  /// 一次只推一條路由。螢幕閱讀器的一次啟動會連點兩下，沒有這道閘門
  /// 就會推兩層同一個頁面——使用者按一次「返回」之後還停在原地，
  /// 而且看不出來自己其實在第二層。
  bool _pushing = false;

  /// 帳號頁的同一道閂鎖（理由見 [_openAccount]：它不能共用 [_pushing]）。
  bool _accountPushing = false;

  @override
  void initState() {
    super.initState();
    // 把已保存的語速套上去，否則使用者的設定要等到下一次播報才生效。
    unawaited(_session.applySpeechRate(_settings.ttsRate));
    _settings.addListener(_applySpeechRate);
  }

  @override
  void dispose() {
    // 一定要解除：`main` 注入的那份 AppSettings 活得比這一頁久，
    // 留著就會在頁面消失之後還去碰 session。
    _settings.removeListener(_applySpeechRate);
    if (_ownsSettings) _settings.dispose();
    super.dispose();
  }

  /// 設定頁改了語速就立刻套用到語音（不必重開 App）。
  void _applySpeechRate() =>
      unawaited(_session.applySpeechRate(_settings.ttsRate));

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.current;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F13),
      body: SafeArea(
        // **可以捲**，不是硬塞：200% 字級下（尤其 en 的長句）三個入口
        // 加起來比一片 640 dp 高的螢幕高。固定佈局會把下半截裁掉，
        // 而被裁掉的正好是最後一站的「設定」——使用者連聽都聽不到它在。
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ExcludeSemantics(
                child: Text(
                  s.homeTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              _modeButton(
                icon: Icons.explore,
                label: s.modeGuidance,
                hint: s.modeGuidanceHint,
                onTap: () => _open(const DemoPage()),
              ),
              const SizedBox(height: 16),
              _modeButton(
                icon: Icons.text_fields,
                label: s.modeReadText,
                hint: s.modeReadTextHint,
                onTap: () => _open(ReadTextPage(session: _session)),
              ),
              const SizedBox(height: 24),
              _settingsEntry(s),
            ],
          ),
        ),
      ),
    );
  }

  /// 次級入口：設定。
  ///
  /// **形狀**（外框 vs 實心）就分得出來這是「附帶的東西」，
  /// 不必靠顏色深淺——低視力與色盲都看不出深淺。
  ///
  /// 但它和兩顆模式按鈕一樣是「**標籤 + 第二行說明**」，說明放在按鈕
  /// **裡面**：只唸「設定」時，螢幕閱讀器唸的是「設定, 按鈕」——一個
  /// 目的地名詞，沒有結果提示，使用者不知道進去能得到什麼（要進去、
  /// 再退出，才知道裡面是什麼）。說明一起唸，才知道是「只調整語音速度」。
  Widget _settingsEntry(AppStrings s) {
    return ConstrainedBox(
      // 不寫死高度：200% 字級時這一行要長高。48 只是 100% 字級下的下限
      // （等於最小觸控目標）；內容超過就往下長，不會被裁掉。
      constraints: const BoxConstraints(minHeight: 48),
      child: OutlinedButton(
        onPressed: () => _open(SettingsPage(
          settings: _settings,
          // 少了這兩個參數，設定頁的帳號列**整列不會建出來**
          // （`settings_page.dart` 的 `if (widget.authService != null)`），
          // 於是 `AuthPage` 在正式入口裡根本到不了 —— 那是審查的 Critical。
          authService: _authService,
          onOpenAccount: _openAccount,
        )),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.settings_outlined, size: 22),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 次級入口的字級比模式小一階：看得出誰是主角，
                  // 但形狀（外框）與說明（第二行）跟模式一致。
                  Text(s.settingsTitle, style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 2),
                  Text(
                    s.settingsHint,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(Widget page) async {
    if (_pushing) return;
    _pushing = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => page),
      );
    } finally {
      _pushing = false;
    }
  }

  /// 設定頁的帳號列被按下時：開帳號頁。
  ///
  /// **刻意不走 [_open]**：那道閂鎖從「設定頁推上去」一直鎖到「設定頁被彈
  /// 回來」（`_open` 等的是整個 push 的 Future），走它帳號頁會永遠推不出來。
  /// 這裡給帳號頁自己一道閂鎖，理由和 [_open] 一樣：螢幕閱讀器一次啟動會
  /// 連點兩下，沒有閂鎖就會推兩層帳號頁。
  void _openAccount() {
    unawaited(_pushAccountPage());
  }

  Future<void> _pushAccountPage() async {
    if (_accountPushing) return;
    _accountPushing = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => AuthPage(
            // 本機 stub，理由見 [_authService]。
            service: _authService,
            // 三種出口（「稍後再說」／登入完成／帳號頁的「回到引導」）都回到
            // 設定頁：使用者就是從那裡進來的，而且 `auth_page.dart` 的契約是
            // 「進去一定出得來」——把使用者留在帳號頁是最嚴重的一種缺陷。
            onSkip: () => Navigator.of(context).pop(),
            onSignedIn: (_) => Navigator.of(context).pop(),
            onBackToGuidance: () => Navigator.of(context).pop(),
          ),
        ),
      );
    } finally {
      _accountPushing = false;
    }
  }

  /// 一個模式按鈕。**100% 字級下至少 72 高**，並帶一句說明。
  ///
  /// 說明放在按鈕**內部**（而不是旁邊的小字）：這樣螢幕閱讀器會把
  /// 「標籤 + 說明」一起唸出來，使用者不必再多滑一次去讀說明。
  ///
  /// 高度寫成 `minHeight`（下限）而不是固定高度，理由跟
  /// `settings_page.dart` 的語速那一列一樣：200% 字級時標籤與說明都會
  /// 折成兩三行，固定 72 會把下半句直接切掉，而切掉的正是「這個模式
  /// 會做什麼」——那句話是看不見的使用者唯一的線索。
  Widget _modeButton({
    required IconData icon,
    required String label,
    required String hint,
    required VoidCallback onTap,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 72),
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
