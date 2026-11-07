import 'dart:async';

import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import 'route_capture_controller.dart';
import 'route_observation_source.dart';

class RouteCapturePage extends StatefulWidget {
  const RouteCapturePage({
    super.key,
    required this.settings,
    required this.onBack,
    this.controller,
    this.previewBuilder,
  });
  final AppSettings settings;
  final VoidCallback onBack;
  final RouteCaptureController? controller;
  final WidgetBuilder? previewBuilder;
  @override
  State<RouteCapturePage> createState() => _RouteCapturePageState();
}

class _RouteCapturePageState extends State<RouteCapturePage>
    with WidgetsBindingObserver {
  late final RouteCaptureController c =
      widget.controller ?? RouteCaptureController();
  bool _leaving = false;
  MemoryImage? _photo;
  bool get _en => widget.settings.language == AppLanguage.english;
  String _t(String zh, String en) => _en ? en : zh;
  @override
  void initState() {
    super.initState();
    c.addListener(_photoChanged);
    _photoChanged();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      c.setForeground(false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) c.setForeground(true);
    // Inactive alone includes the camera permission sheet, not just background.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      c.setForeground(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_photoChanged);
    final photo = _photo;
    _photo = null;
    if (photo != null) unawaited(photo.evict());
    if (widget.controller == null) {
      c.dispose();
    } else {
      unawaited(c.stop());
    }
    super.dispose();
  }

  void _photoChanged() {
    final bytes = c.keyframe?.bytes;
    if (identical(_photo?.bytes, bytes)) return;
    final previous = _photo;
    _photo = bytes == null ? null : MemoryImage(bytes);
    if (previous != null) unawaited(previous.evict());
  }

  Future<void> _back() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    await c.stop();
    if (mounted) widget.onBack();
  }

  String _status() {
    if (c.capturing) {
      return _t('正在取相，可隨時停止。', 'Taking a photo. You can stop at any time.');
    }
    return switch (c.status) {
      RouteCaptureStatus.idle => _t(
        '準備好後按「開始相機」。',
        'Choose Start camera when ready.',
      ),
      RouteCaptureStatus.starting => _t(
        '正在開啟相機，可隨時停止。',
        'Starting camera. You can stop at any time.',
      ),
      RouteCaptureStatus.stopping => _t('正在停止相機…', 'Stopping camera…'),
      RouteCaptureStatus.running => _t(
        '相機已開啟，可取一張相。',
        'Camera is on. You can take a photo.',
      ),
      RouteCaptureStatus.captured => _t(
        '已取得相片，暫留此頁。',
        'Photo captured and held on this page.',
      ),
      RouteCaptureStatus.stopped => _t(
        '相機已停止，相片已清除。',
        'Camera stopped. Photo cleared.',
      ),
      RouteCaptureStatus.paused => _t(
        '相機已暫停，請明確重新開始。',
        'Camera paused. Start again when ready.',
      ),
      RouteCaptureStatus.permission => _t(
        '未獲相機權限。可到系統設定檢查，再重新嘗試或返回。',
        'Camera access is not allowed. Check system settings, then retry or go back.',
      ),
      RouteCaptureStatus.unsupported => _t(
        '此裝置暫未支援錄路相機，可返回其他功能。',
        'Route camera is not supported on this device. Go back to other features.',
      ),
      RouteCaptureStatus.unavailable => _t(
        '相機暫不可用，請停止後重試或返回。',
        'Camera is unavailable. Stop and retry, or go back.',
      ),
      RouteCaptureStatus.noFrame => _t(
        '暫時未有畫面，請稍候再取相。',
        'No frame yet. Wait briefly and try another photo.',
      ),
      RouteCaptureStatus.busy => _t(
        '仍在處理上一張相片，請稍候再取相或停止。',
        'Still processing the previous photo. Wait and retry, or stop.',
      ),
      RouteCaptureStatus.unknownClock ||
      RouteCaptureStatus.staleFrame ||
      RouteCaptureStatus.futureFrame => _t(
        '畫面時間未能確認或已過期，請重新取相。',
        'Frame time is unknown or expired. Take another photo.',
      ),
      RouteCaptureStatus.cancelled => _t(
        '取相已取消，可再取相或停止。',
        'Capture cancelled. Take another photo or stop.',
      ),
      RouteCaptureStatus.stopUnconfirmed => _t(
        '尚未確認相機已停止。請稍候重試或返回。',
        'Camera stop is not yet confirmed. Wait and retry, or go back.',
      ),
      RouteCaptureStatus.invalid => _t(
        '畫面資料未能核對，請再取相或停止後重試。',
        'Could not verify the frame. Take another photo, or stop and retry.',
      ),
      RouteCaptureStatus.failed => _t(
        '操作暫未完成，請停止後重試或返回。',
        'Could not complete the action. Stop and retry, or go back.',
      ),
    };
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_back());
    },
    child: Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([c, widget.settings]),
          builder: (context, _) => Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          _t('錄路相機試驗', 'Route camera trial'),
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _status(),
                          key: const ValueKey('capture-status'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _t(
                          '開始後才使用相機；相片只暫留此頁，尚未保存為路線。',
                          'The camera starts only on request. Photos stay on this page and are not saved as a route.',
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (c.running)
                        ExcludeSemantics(
                          child: SizedBox(
                            height: 240,
                            child:
                                widget.previewBuilder?.call(context) ??
                                const UiKitView(
                                  viewType: 'hk.pathguide/route_camera/preview',
                                ),
                          ),
                        ),
                      if (_photo case final photo?) ...[
                        const SizedBox(height: 12),
                        Image(
                          image: photo,
                          key: const ValueKey('captured-photo'),
                          height: 180,
                          fit: BoxFit.contain,
                          excludeFromSemantics: true,
                          errorBuilder: (_, _, _) => Text(
                            _t(
                              '相片未能顯示，可重新取相。',
                              'Photo could not be displayed. Take another photo.',
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton(
                      key: const ValueKey('capture-primary'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: _leaving
                          ? null
                          : c.canCapture
                          ? () => unawaited(c.capture())
                          : c.canStart
                          ? () => unawaited(c.start())
                          : null,
                      child: Text(
                        c.running
                            ? _t('取一張相', 'Take a photo')
                            : [
                                RouteCaptureStatus.idle,
                                RouteCaptureStatus.stopped,
                              ].contains(c.status)
                            ? _t('開始相機', 'Start camera')
                            : _t('重新嘗試', 'Retry camera'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            key: const ValueKey('capture-stop'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                            ),
                            onPressed: _leaving
                                ? null
                                : () => unawaited(c.stop()),
                            child: Text(_t('停止', 'Stop')),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            key: const ValueKey('capture-back'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                            ),
                            onPressed: _leaving
                                ? null
                                : () => unawaited(_back()),
                            child: Text(_t('返回', 'Back')),
                          ),
                        ),
                      ],
                    ),
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
