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
    try {
      final parsed =
          parseModelManifest(await rootBundle.loadString(defaultModelManifestKey));
      final m = parsed.manifest;
      if (m == null) return null;
      // `ModelManifest.bytes` 是 `int?`（清單可能沒寫），所以不能直接除。
      final bytes = m.bytes;
      final size = bytes == null
          ? '—'
          : '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
      return '${m.modelClassCount} 類 · $size · ${m.version}';
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
                SizedBox(
                  height: 56,
                  child: TextButton(
                    onPressed: () async {
                      await widget.settings.setSpeechSpeed(speed);
                      if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                    },
                    child: Text(
                      _speedLabel(s, speed),
                      style: const TextStyle(
                        fontSize: 18,
                        color: AppColors.onSurface,
                      ),
                    ),
                  ),
                ),
            ],
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
              SizedBox(
                height: 60,
                child: OutlinedButton(
                  onPressed: _pickSpeed,
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          s.speechSpeed,
                          style: const TextStyle(fontSize: 17),
                        ),
                      ),
                      Text(
                        _speedLabel(s, widget.settings.speechSpeed),
                        style: const TextStyle(color: AppColors.accent, fontSize: 17),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Semantics(
                readOnly: true,
                label: s.modelInfo,
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
                      FutureBuilder<String?>(
                        future: _summary,
                        builder: (context, snap) => Text(
                          snap.data ?? '—',
                          style: const TextStyle(
                            color: AppColors.onSurface,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
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
