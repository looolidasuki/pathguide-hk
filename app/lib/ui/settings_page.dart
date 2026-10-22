import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../l10n/app_strings.dart';
import '../settings/app_settings.dart';
import '../vision/model_manifest.dart';
import '../vision/platform_vision.dart' show defaultModelManifestKey;
import 'app_theme.dart';

/// 設定頁。只有兩塊內容，**刻意不做第三塊**。
///
/// 為什麼沒有「未來功能」清單：那種列表對看不見的使用者是純噪音——
/// 每一項都要花一次焦點移動去聽「這個還沒做」。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.settings, this.modelSummary});

  final AppSettings settings;

  /// 模型資訊的一行摘要。預設從端上清單讀；測試注入固定字串。
  final Future<String?> Function()? modelSummary;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Future<String?> _summary =
      (widget.modelSummary ?? _loadModelSummary)();

  static Future<String?> _loadModelSummary() async {
    final s = AppStrings.current;
    try {
      final parsed =
          parseModelManifest(await rootBundle.loadString(defaultModelManifestKey));
      final m = parsed.manifest;
      if (m == null) return null;
      // `ModelManifest.bytes` 是 `int?`（清單可能沒寫），所以不能直接除。
      final bytes = m.bytes;
      // 這整行是文案（「類」與「MB」都要能翻），所以拼字留在 `AppStrings`。
      return s.modelSummaryLine(
        classCount: m.modelClassCount,
        sizeText: bytes == null
            ? s.modelSizeUnknown
            : s.modelSize(bytes / (1024 * 1024)),
        version: m.version,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _pickSpeed() async {
    final s = AppStrings.current;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: AnimatedBuilder(
          animation: widget.settings,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final speed in SpeechSpeed.values)
                _speedChoice(sheetContext, s, speed),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _selectSpeed(BuildContext sheetContext, SpeechSpeed speed) async {
    await widget.settings.setSpeechSpeed(speed);
    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
  }

  /// 面板上的一列語速。
  ///
  /// 為什麼外面是 `Semantics` + 內層 `ExcludeSemantics`：內層 `Text` 會自己
  /// 長成一個語意節點，使用者於是先聽「慢」、再聽「慢，已選取」——兩站講同一件事。
  /// 而 `ExcludeSemantics` 會連 `TextButton` 自帶的 tap 動作一起丟掉，
  /// 所以外層要自己給 `onTap`，否則這一列在 TalkBack 裡按不動。
  Widget _speedChoice(
    BuildContext sheetContext,
    AppStrings s,
    SpeechSpeed speed,
  ) {
    final name = _speedLabel(s, speed);
    final selected = widget.settings.speechSpeed == speed;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: s.speechSpeedChoice(name, selected: selected),
      onTap: () => _selectSpeed(sheetContext, speed),
      child: ExcludeSemantics(
        child: ConstrainedBox(
          // 不寫死高度：200% 字級時這一列要長高。56 只是 100% 字級下的下限
          // （> 48 的最小觸控目標），內容超過就往下長，不會被裁掉。
          constraints: const BoxConstraints(minHeight: 56),
          child: TextButton(
            onPressed: () => _selectSpeed(sheetContext, speed),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              alignment: AlignmentDirectional.centerStart,
            ),
            child: Row(
              children: <Widget>[
                // 選中與否**不只靠顏色**：勾勾是形狀，低視力與色盲都分得出來；
                // 看不見的人聽的是標籤裡的「已選取」。
                SizedBox(
                  width: 32,
                  child: selected
                      ? const Icon(Icons.check,
                          size: 24, color: AppColors.accent)
                      : null,
                ),
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                      fontSize: 18,
                      color: AppColors.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _speedLabel(AppStrings s, SpeechSpeed speed) => switch (speed) {
        SpeechSpeed.slow => s.speechSpeedSlow,
        SpeechSpeed.normal => s.speechSpeedNormal,
        SpeechSpeed.fast => s.speechSpeedFast,
      };

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.current;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.settings,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: <Widget>[
              ExcludeSemantics(
                child: Text(
                  s.settingsTitle,
                  style: const TextStyle(
                    color: AppColors.onSurface,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                s.settingsHint,
                style: const TextStyle(color: AppColors.onSurfaceMuted, fontSize: 13),
              ),
              const SizedBox(height: 20),
              // 標籤自己說「現況 + 點兩下會怎樣」：只唸「播報速度，正常」時，
              // 使用者不知道這是一顆按鈕、也不知道按下去會發生什麼。
              Semantics(
                container: true,
                button: true,
                label: s.speechSpeedAction(
                  _speedLabel(s, widget.settings.speechSpeed),
                ),
                onTap: _pickSpeed,
                child: ExcludeSemantics(
                  child: ConstrainedBox(
                    // 不寫死高度：en 的「Speech speed」在 200% 字級下會折成兩行，
                    // 以前固定 60 就直接切掉。60 只是 100% 字級下的下限。
                    constraints: const BoxConstraints(minHeight: 60),
                    child: OutlinedButton(
                      onPressed: _pickSpeed,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                s.speechSpeed,
                                style: const TextStyle(fontSize: 17),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _speedLabel(s, widget.settings.speechSpeed),
                              style: const TextStyle(
                                color: AppColors.accent,
                                fontSize: 17,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // 整塊**一個**語意節點：標題唸一次、摘要唸一次。
              //
              // 以前是 `Semantics(label: 標題)` 包住一個同名 `Text`，於是
              // 標題被唸兩次（Flutter 合併 label，不去重），而摘要自己又是
              // 一個沒合併的節點——三個節點講兩句話。
              FutureBuilder<String?>(
                future: _summary,
                builder: (context, snap) {
                  final summary = snap.data;
                  // 讀不到就說「載入中」，**不唸破折號**：螢幕閱讀器唸「—」
                  // 是 “dash”，等於什麼都沒說。
                  final shown = (summary == null || summary.isEmpty)
                      ? s.modelInfoLoading
                      : summary;
                  return Semantics(
                    container: true,
                    readOnly: true,
                    label: s.modelInfoSpoken(shown),
                    child: ExcludeSemantics(
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              s.modelInfo,
                              style: const TextStyle(
                                color: AppColors.onSurfaceMuted,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              shown,
                              style: const TextStyle(
                                color: AppColors.onSurface,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back, size: 22),
                  label: Text(s.backToHome),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
