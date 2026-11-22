import 'dart:async';

import 'package:flutter/material.dart';

import '../route_memory/route_observation_source.dart';
import '../settings/app_settings.dart';
import '../tts/flutter_tts_speaker.dart';
import '../tts/speech_coordinator.dart';
import 'scene_backend.dart';
import 'scene_controller.dart';

class ScenePage extends StatefulWidget {
  const ScenePage({
    super.key,
    required this.settings,
    required this.onBack,
    this.controller,
  });
  final AppSettings settings;
  final VoidCallback onBack;
  final SceneController? controller;
  @override
  State<ScenePage> createState() => _ScenePageState();
}

class _ScenePageState extends State<ScenePage> with WidgetsBindingObserver {
  late final FlutterTtsSpeaker tts;
  late final SceneController c;
  @override
  void initState() {
    super.initState();
    tts = FlutterTtsSpeaker(
      cantoneseOnly: true,
      speechRate: widget.settings.speechSpeed.rate,
      onStarted: () => c.speechStarted(),
    );
    c =
        widget.controller ??
        SceneController(
          source: RouteObservationSource(),
          backend: FirebaseSceneBackend(),
          voice: SpeechCoordinator(tts),
        );
    WidgetsBinding.instance.addObserver(this);
    widget.settings.addListener(_settingsChanged);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      c.foreground(false);
    }
  }

  void _settingsChanged() =>
      unawaited(tts.setSpeechRate(widget.settings.speechSpeed.rate));
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) c.foreground(true);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      c.foreground(false);
    }
  }

  void _back() {
    c.invalidate();
    widget.onBack();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.settings.removeListener(_settingsChanged);
    if (widget.controller == null) {
      c.dispose();
    } else {
      c.invalidate();
    }
    super.dispose();
  }

  String get status => !c.supported
      ? '此裝置尚未接通取相功能。請使用支援的 iPhone 版本。'
      : switch (c.status) {
          SceneStatus.idle => '準備好後，按「描述前方」。',
          SceneStatus.capturing => '正在取相，可隨時取消。',
          SceneStatus.analysing => '正在分析，可隨時取消。',
          SceneStatus.complete =>
            c.failure == 'speech-unavailable'
                ? '描述完成，廣東話播音未能開始；可閱讀文字結果。'
                : '描述完成。',
          SceneStatus.cancelled =>
            c.failure == 'expired' ? '畫面已過期，描述已作廢。' : '已取消，舊回答不會播出。',
          SceneStatus.failed => switch (c.failure) {
            'not-configured' => '手機場景功能未配置，或尚未登入。',
            'app-check-unavailable' =>
              '手機驗證未完成（App Check）；登入成功亦可能出現，請由開發者核對驗證設定。',
            'unauthenticated' => '登入或手機驗證未通過，請由開發者核對；沒有自動重試。',
            'failed-precondition' => '後端試驗設定未完成，請由開發者核對；不是要求你重新輸入Qwen Key。',
            'rejected' || 'invalid-answer' => '未收到完整而合適的描述。可自行重新取相。',
            'noFrame' || 'staleFrame' => '未取得新畫面，請稍候再按「描述前方」。',
            'resource-exhausted' || 'busy' => '上一個請求尚未結束，或暫時達到請求限制。請稍後再試。',
            'deadline-exceeded' => '分析逾時，沒有自動重試。',
            _ => '描述或廣東話播音未完成。請檢查網絡、相機權限及廣東話語音，再自行重試。',
          },
        };
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: c,
          builder: (context, _) => Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        '描述前方',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Text(status, key: const ValueKey('scene-status')),
                    ),
                    if (c.text != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          c.text!,
                          key: const ValueKey('scene-result'),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    if (c.busy && c.status == SceneStatus.cancelled)
                      const Text('正在等候原請求結束；取消不代表雲端停止計費，亦不會補播舊回答。'),
                    const SizedBox(height: 12),
                    if (!const bool.fromEnvironment('dart.vm.product') &&
                        const bool.fromEnvironment('APP_CHECK_DEBUG'))
                      const Text('開發測試驗證模式：只供指定手機與帳戶試驗，不代表正式DeviceCheck通過。'),
                    if (const bool.fromEnvironment('SCENE_DESCRIPTION_TRIAL'))
                      const Text(
                        '本次只測房間枱、椅、門；最多20次，Qwen估算額US\$0.01。不足下一次預留、或用量未能確認時會提早停止。',
                      ),
                    const Text(
                      '每次按下會取一張相，傳到 Qwen 作雲端分析，可能產生費用。App 不會自動保存原圖或完整回答；供應商的資料政策另行適用。',
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '請站定使用。這是畫面描述，不能判斷距離或是否可以通行。尚未接通明顯轉向偵測；轉向前請按取消，重新站定後再取相。',
                    ),
                    ExpansionTile(
                      title: const Text('用量與耗時'),
                      children: [
                        Text(
                          '取相：${c.captureMs?.toString() ?? '未取得'} ms；上傳及回覆：${c.uploadModelMs?.toString() ?? '未取得'} ms；取相開始至播音開始：${c.speechStartMs?.toString() ?? '未收到語音開始事件'} ms。',
                        ),
                        Text(
                          '模型處理：${c.metrics?.modelMs.toString() ?? '未取得'} ms；輸入／輸出 tokens：${c.metrics?.promptTokens ?? '缺失'}／${c.metrics?.completionTokens ?? '缺失'}。',
                        ),
                        Text(
                          c.metrics?.estimatedUsd == null
                              ? '估算費用：缺少有效 usage 或已配置費率。'
                              : '估算 US\$${c.metrics!.estimatedUsd!.toStringAsFixed(6)}，不是帳單硬上限。',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton(
                      onPressed: c.canDescribe
                          ? () => unawaited(c.describe())
                          : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(64),
                      ),
                      child: const Text('描述前方'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => c.invalidate(),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                      ),
                      child: const Text('取消描述及播音'),
                    ),
                    TextButton(onPressed: _back, child: const Text('返回')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
