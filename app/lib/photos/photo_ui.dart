import '../l10n/app_language.dart';

import 'package:flutter/material.dart';

import 'photo_controller.dart';

class PhotoScope extends InheritedNotifier<PhotoController> {
  const PhotoScope({
    super.key,
    required PhotoController controller,
    required super.child,
  }) : super(notifier: controller);
  static PhotoController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PhotoScope>()?.notifier;
}

class PhotoEntry extends StatelessWidget {
  const PhotoEntry({super.key});
  @override
  Widget build(BuildContext context) {
    if (PhotoScope.maybeOf(context) == null) return const SizedBox.shrink();
    return OutlinedButton.icon(
      onPressed: () =>
          Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => const PhotoPage())),
      icon: const Icon(Icons.cloud_upload_outlined),
      label: const AppText('個人模型照片收集'),
    );
  }
}

class PhotoPage extends StatefulWidget {
  const PhotoPage({super.key});
  @override
  State<PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<PhotoPage> {
  Future<void> _enable(PhotoController c) async {
    final uid = c.account.identity?.uid;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const AppText('同意個人模型照片用途'),
        content: const AppText(
          '開啟後，可手動回報環境照片；自動擷取須另外開啟。照片可能包含旁人或文字，請避免拍攝私人文件。\n\n照片綁定你的帳號，僅供本人個人模型資料準備及獲授權組員人工覆核，不自動加入共用模型。照片不含定位，不錄影；模型預測未經確認。\n\n本機加密待傳最多 50 張或 50 MB，七日到期；只經 Wi-Fi 上傳。雲端未覆核照片最多保留三十日，之後刪除。\n\n關閉收集會停止新擷取、停止待傳並清除本機待傳照片；雲端既有照片依保留規則處理。刪除帳號會清理本階段雲端照片。拒絕不影響基本辨識。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const AppText('不同意'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const AppText('同意並開啟'),
          ),
        ],
      ),
    );
    if (yes == true && c.account.identity?.uid == uid) await c.setEnabled(true);
  }

  @override
  Widget build(BuildContext context) {
    final c = PhotoScope.maybeOf(context)!;
    return Scaffold(
      appBar: AppBar(
        title: const AppText('個人模型照片收集'),
        leading: BackButton(onPressed: () => Navigator.pop(context)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (!c.backend.configured)
            const AppText(
              '照片雲端服務尚未配置。需先設定 Storage、Functions 及 App Check；目前不會擷取或上傳照片。',
            ),
          if (c.account.identity == null) const AppText('請先在帳號頁登入；基本辨識毋須登入。'),
          Semantics(
            liveRegion: true,
            child: AppText(c.enabled ? '照片收集已開啟' : '照片收集已關閉'),
          ),
          AppText('待傳照片：${c.count} 張'),
          AppText(
            '雲端最近最多二十筆：${c.cloudProgress.length} 張；待覆核 ${c.cloudProgress.where((p) => p["reviewStatus"] == "pending").length} 張。',
          ),
          if (c.message != null)
            Semantics(liveRegion: true, child: AppText(c.message!)),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: c.available && !c.busy
                ? () => c.enabled ? c.setEnabled(false) : _enable(c)
                : null,
            child: AppText(c.enabled ? '關閉收集並清除待傳' : '閱讀用途並開啟收集'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const AppText('受控自動擷取'),
            subtitle: const AppText('只在即時辨識中運作；低信心候選及少量場景抽樣不代表新物件。'),
            value: c.autoCapture,
            onChanged: c.canCapture ? c.setAutomatic : null,
          ),
          OutlinedButton(
            onPressed: c.canCapture ? c.uploadPending : null,
            child: const AppText('經 Wi-Fi 上傳待傳照片'),
          ),
          OutlinedButton(
            onPressed: c.busy ? null : () => c.refresh(),
            child: const AppText('重新檢查同意及服務狀態'),
          ),
          TextButton(
            onPressed: () async {
              final yes = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const AppText('清除本機待傳照片？'),
                  content: const AppText('這只清除手機待傳，不會刪除已上傳的雲端照片。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const AppText('取消'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const AppText('清除待傳'),
                    ),
                  ],
                ),
              );
              if (yes == true) await c.clearPending();
            },
            child: const AppText('清除本機待傳照片'),
          ),
          const AppText('上傳成功只代表等待人工覆核，並不代表已完成訓練或模型已有改善。'),
        ],
      ),
    );
  }
}
