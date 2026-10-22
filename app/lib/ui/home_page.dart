import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../settings/app_settings.dart';
import '../vision/vision_session.dart';
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
/// - **按鈕加大**（每個 72 高）：低視力使用者的觸控精確度通常較差，
///   而這是全 App 最常按的兩個東西。
/// - 每個模式都有一句說明，**進入後也會再播報一次**自己在哪裡。
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.session, this.settings});

  /// 相機與語音的共用持有者。預設自己建一個；測試注入假的。
  final VisionSession? session;

  /// 使用者設定。沒注入就建一個純記憶體的（測試、或直接開這一頁時）。
  final AppSettings? settings;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final VisionSession _session = widget.session ?? VisionSession();
  late final AppSettings _settings = widget.settings ?? AppSettings.memory();

  /// 自己建的設定才由自己釋放；`main` 注入的那份比這一頁活得久，不能動。
  bool get _ownsSettings => widget.settings == null;

  /// 一次只推一條路由。螢幕閱讀器的一次啟動會連點兩下，沒有這道閘門
  /// 就會推兩層同一個頁面——使用者按一次「返回」之後還停在原地，
  /// 而且看不出來自己其實在第二層。
  bool _pushing = false;

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
        child: Padding(
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
              // 次級入口：**形狀**（外框 vs 實心）就分得出來是「附帶的東西」，
              // 不必靠顏色深淺——低視力與色盲都看不出深淺。
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: () => _open(SettingsPage(settings: _settings)),
                  icon: const Icon(Icons.settings_outlined, size: 22),
                  label: Text(
                    s.settingsTitle,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
              const Spacer(),
            ],
          ),
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

  /// 一個模式按鈕。**高度刻意做大**（72），並帶一句說明。
  ///
  /// 說明放在按鈕**內部**（而不是旁邊的小字）：這樣螢幕閱讀器會把
  /// 「標籤 + 說明」一起唸出來，使用者不必再多滑一次去讀說明。
  Widget _modeButton({
    required IconData icon,
    required String label,
    required String hint,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 72,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20),
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
