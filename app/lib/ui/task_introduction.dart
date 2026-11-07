import 'package:flutter/material.dart';

import '../l10n/app_language.dart';
import '../settings/app_settings.dart';

Future<bool?> showTaskIntroduction(BuildContext context, AppTask task) {
  final (action, result) = switch (task) {
    AppTask.recognition => ('將相機對準前方，開始後聽取物件名稱。', '只辨識支援的物件；不代表前方暢通。可隨時暫停或返回。'),
    AppTask.navigation => (
      '選擇搜尋目的地、我的路線或錄製新路線。',
      '搜尋提供戶外步行路線；室內可錄路標並逐點重認，樓層及方向須自行確認。',
    ),
    AppTask.menu => ('拍攝或選取菜單，再用文字或語音查詢。', '閱讀可確認的菜名及價格；讀不到或配對不明時可重拍。'),
    AppTask.routeCamera => (
      '按開始開啟相機，再按「取一張相」檢查畫面。',
      '只暫存一張相；停止或返回會清除，尚未保存為路線。',
    ),
    AppTask.routeMock => (
      '使用預設合成路標，試錄製、命名及回放；可開啟跨樓層樣例。',
      '畫面只演示狀態轉換，不會開相機、定位或帶你行路。',
    ),
    AppTask.landmarkReplay => ('選擇預設樣例，逐步查看路標及提示。', '提示來自樣例資料，不會判斷你身處的位置。'),
    AppTask.depth => ('將相機對準物件，查看辨識及支援硬件提供的距離。', '距離功能需要支援的深度感測；此試驗不提供避障指令。'),
    AppTask.visionDiagnostics => (
      '進入後開啟相機；在「更多操作」比較模型、模擬資料及門檻。',
      '這些控制用於診斷；一般辨識毋須調整。可隨時暫停或返回。',
    ),
  };
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      title: const AppText('開始前'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(action),
          const SizedBox(height: 16),
          AppText(result),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const AppText('返回'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const AppText('略過說明'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const AppText('開始'),
        ),
      ],
    ),
  );
}
