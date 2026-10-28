import '../l10n/app_language.dart';

import 'package:flutter/material.dart';

Future<void> showUsageGuide(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    scrollable: true,
    title: const AppText('使用教學'),
    content: const AppText(
      '在首頁選擇「即時辨識」便會啟動相機及自動播報；首次使用需要允許相機權限。\n\n'
      '把手機後置相機朝向要辨識的環境，保持穩定；避免手指遮住鏡頭。\n\n'
      '「更多操作」內可重播目前結果、開關播報及調整辨識設定；「暫停辨識」會停止相機及播報。'
      '中斷後返回 App 會自動恢復辨識；手動暫停則需要按「繼續辨識」。\n\n'
      '開啟 VoiceOver 後，可左右輕掃選擇項目，再雙擊啟動目前項目；'
      '雙擊不需要落在按鈕的位置。Android 請使用 TalkBack 的標準操作。\n\n'
      '讀屏開啟時同樣會自動播報物件，不需要逐次按按鈕取得結果。'
      '沒有辨識結果不代表前方安全；本版不提供距離、扶手電梯方向或避障指令。\n\n'
      '菜單閱讀：先拍攝或選取菜單，再按語音搜尋講出菜式，例如我想食牛腩飯。'
      '會自動搜尋並朗讀可確認的價錢；亦可用文字修改搜尋。菜單文字在 iPhone 本機辨識，不加入訓練照片。'
      '若手機未提供離線粵語，使用 Apple 線上語音前會另外詢問；錄音只在你啟動語音搜尋時進行。\n\n'
      '路線導航：輸入或講出香港目的地，核對名稱、地址及步行路線後按開始導航。'
      '導航期間可以重播下一步、查詢位置、暫停或結束。切到背景即暫停，返回後需按繼續導航。'
      '定位不足時停止精確指示；接近終點後請自行確認入口。路線的樓梯、升降機及入口未經實地核實。'
      '收藏只存在此手機，使用時重新計算路線；Android 需要 Google Play 服務及已配置的路線服務。\n\n'
      '基本辨識毋須登入；個人模型照片須另外配置及同意。你可以關閉教學，之後從設定再次閱讀。',
    ),
    actions: <Widget>[
      TextButton(
        style: TextButton.styleFrom(minimumSize: const Size(56, 56)),
        onPressed: () => Navigator.of(context).pop(),
        child: const AppText('關閉教學'),
      ),
    ],
  ),
);
