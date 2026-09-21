import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/demo_page.dart';

/// 領路通 · PathGuide HK —— M3 最小可见 Demo。
///
/// 这一版**只做可见性验证**，明确不做（见毕设设计 §9.1）：
/// 导航 API、路线规划、决策状态机、语音输入、室内地图。
///
/// 当前能看到：相机实时画面 + 检测框 + 中文类别 + FPS 与推理耗时 +
/// 阈值滑条 + 粤语播报。当前**只有「垃圾桶」一类有训练数据**，
/// 其余类别不会出框——这是数据缺口，不是程序故障。
void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 室外强光下演示，深色系统栏更省电也更清楚。
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Color(0xFF161B22),
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF161B22),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(const PathGuideApp());
}

class PathGuideApp extends StatelessWidget {
  const PathGuideApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '領路通',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: Brightness.dark,
        ),
      ),
      home: const DemoPage(),
    );
  }
}
