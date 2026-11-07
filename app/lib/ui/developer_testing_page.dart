import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../l10n/app_language.dart';
import '../vision/model_manifest.dart';
import '../vision/platform_vision.dart' show defaultModelManifestKey;

/// Deliberate entry to tools which do not deliver an indoor journey.
class DeveloperTestingPage extends StatefulWidget {
  const DeveloperTestingPage({
    super.key,
    required this.onBack,
    required this.onCamera,
    required this.onRouteMock,
    required this.onReplay,
    required this.onDepth,
    required this.onVisionDiagnostics,
  });
  final VoidCallback onBack;
  final VoidCallback onCamera;
  final VoidCallback onRouteMock;
  final VoidCallback onReplay;
  final VoidCallback onDepth;
  final VoidCallback onVisionDiagnostics;

  @override
  State<DeveloperTestingPage> createState() => _DeveloperTestingPageState();
}

class _DeveloperTestingPageState extends State<DeveloperTestingPage> {
  late final Future<ManifestParseResult> _manifest = rootBundle
      .loadString(defaultModelManifestKey, cache: false)
      .then(parseModelManifest)
      .catchError((Object error) => ManifestParseResult.fail('$error'));

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back),
            label: const AppText('返回設定'),
          ),
        ),
        Semantics(
          header: true,
          child: AppText(
            '開發測試',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ),
        const SizedBox(height: 12),
        const AppText('以下工具用來檢查個別功能，尚未連成室內錄路及導航流程。'),
        const SizedBox(height: 20),
        _entry(
          context,
          '錄路相機試驗',
          '只檢查預覽及取相；相片暫存此頁，不會保存路線或提供導航。',
          widget.onCamera,
        ),
        _entry(
          context,
          '室內路線工具（試驗）',
          '用合成路標試錄製、回放及跨樓層；不會開相機或定位。',
          widget.onRouteMock,
        ),
        _entry(context, '室內路標回放（樣例）', '回放預設路標及提示；不會判斷你身處的位置。', widget.onReplay),
        _entry(
          context,
          '物件與測距（試驗）',
          '用相機及支援的深度感測檢查物件距離；不提供避障指令。',
          widget.onDepth,
        ),
        _entry(
          context,
          '辨識與模型診斷',
          '比較辨識模型、模擬資料及門檻，查看技術資料。進入後會開相機。',
          widget.onVisionDiagnostics,
        ),
        ExpansionTile(
          title: const AppText('模型資料'),
          children: [
            FutureBuilder<ManifestParseResult>(
              future: _manifest,
              builder: (context, snapshot) {
                final m = snapshot.data?.manifest;
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: AppText(
                    m == null
                        ? '清單暫時不可用'
                        : '版本 ${m.version} · ${m.modelClassCount} 類'
                              '${m.bytes == null ? '' : ' · ${(m.bytes! / 1000000).toStringAsFixed(2)} MB'}',
                  ),
                );
              },
            ),
          ],
        ),
      ],
    ),
  );

  Widget _entry(
    BuildContext context,
    String title,
    String description,
    VoidCallback onTap,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.all(20),
        alignment: Alignment.centerLeft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          AppText(description, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    ),
  );
}
