import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../overlay/box_painter.dart';
import '../tts/announcer.dart';
import '../tts/flutter_tts_speaker.dart';
import '../vision/detection.dart';
import '../vision/mock_vision_source.dart';
import '../vision/platform_vision.dart';
import '../vision/single_class_map.dart';
import '../vision/vision_preview.dart';
import '../vision/vision_source.dart';

/// 检测来源：真实相机（原生 CameraX + LiteRT）或假数据。
enum SourceMode {
  /// 真实相机，Android 走原生 CameraX。
  camera,

  /// 按已知规律运动的假框，用来校验坐标映射与演示防抖，不需要模型。
  mock,
}

/// M3 最小可见 Demo 的主界面。
///
/// 验收目标（见毕设设计 §9.1）：相机实时画面 + 检测框 + 中文标签 +
/// FPS 与推理耗时 + 阈值滑条 + 粤语播报。
class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  final PlatformVision _platform = PlatformVision();
  final FlutterTtsSpeaker _speaker = FlutterTtsSpeaker();
  late final Announcer _announcer = Announcer(speaker: _speaker);

  StreamSubscription<VisionFrame>? _sub;

  SourceMode _mode = SourceMode.camera;
  MockVisionSource? _mock;

  double _threshold = 0.30;
  bool _speakEnabled = true;
  bool _showLabels = true;

  List<Detection> _detections = const <Detection>[];
  Size _frameSize = const Size(1280, 720);
  /// 当前帧的旋转角。目前固定 90°：Android 后置相机在竖屏下输出横屏帧，
  /// 需顺时针转 90° 才正立。HUD 常显它，框画偏时这是第一嫌疑。
  static const int _rotationDegrees = 90;

  double _inferenceMs = 0;
  double _fps = 0;
  DateTime _lastFrameAt = DateTime.now();

  String _status = '正在初始化…';
  bool _modelReady = false;
  String? _ttsLanguage;

  /// 模型能力的一句话说明（单类模型时提醒「其余类别不会出框」）。
  String? _modelNote;

  /// 原生侧诊断快照，定时轮询后显示在 HUD 上。
  VisionDiagnostics? _diagnostics;
  Timer? _diagTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    await _initSpeaker();
    await _requestCamera();
    await _startCameraSource();
  }

  Future<void> _initSpeaker() async {
    final lang = await _speaker.initialize();
    if (!mounted) return;
    setState(() {
      _ttsLanguage = lang;
      if (lang != null && !_speaker.isCantonese) {
        // 落到普通话语音时必须显式提示：否则演示时会被误以为在念粤语。
        _status = '警告：未找到粤语语音包，当前使用 $lang';
      }
    });
  }

  /// 请求相机权限并启动预览。
  ///
  /// 权限申请**在原生侧**完成（见 `VisionPlugin.requestPermissionThenStart`）。
  /// 刻意不用 permission_handler：它会传递引入 `objective_c`，而那个包的
  /// build hook 在含空格的路径上会让 `flutter test` 直接失败。
  Future<void> _requestCamera() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final started = await _platform.startPreview();
    if (!mounted) return;
    if (!started) {
      setState(() => _status = '相机未启动：可能未授予权限，或设备被其他程序占用');
    }
  }

  Future<void> _startCameraSource() async {
    await _sub?.cancel();

    // 单类模型需要把它的 0 映射回项目类别表里的真实 id。
    // 这里先按「单类模型」假设去加载，拿到模型真实类别数后再据此提示。
    final ok = await _platform.loadModel(
      classOffset: singleClassProjectId ?? 0,
    );
    if (!mounted) return;

    final mapping = resolveMapping(
      modelClassCount: _platform.modelClassCount,
      singleClassOriginalId: singleClassProjectId,
      singleClassName: singleClassProjectName ?? '',
    );
    setState(() {
      _modelReady = ok;
      _modelNote = ok && mapping != null ? mapping.describe() : null;
      _status = ok
          ? '模型已加载（模型类别数 ${_platform.modelClassCount}'
              '${_platform.classOffset > 0 ? "，已偏移到类别 ${_platform.classOffset}" : ""}'
              '，输入 ${_platform.inputSize}）'
          : '模型未加载：${_platform.error ?? "未知原因"}';
    });
    _sub = _platform.frames.listen(_onFrame, onError: (Object e) {
      if (mounted) setState(() => _status = '推理流出错：$e');
    });

    // 轮询原生诊断计数。相机链路的失败点在界面上长得一模一样，
    // 必须靠这些计数区分（分析帧为 0 / 有错误 / 最高分太低）。
    _diagTimer?.cancel();
    _diagTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final d = await _platform.diagnostics();
      if (mounted && d != null) setState(() => _diagnostics = d);
    });
  }

  Future<void> _startMockSource() async {
    await _sub?.cancel();
    await _platform.release();
    final mock = MockVisionSource(threshold: _threshold);
    _mock = mock;
    await mock.initialize();
    _sub = mock.frames.listen(_onFrame);
    if (mounted) {
      setState(() {
        _modelReady = false;
        _status = '假数据模式：验证坐标映射与防抖，不接模型';
      });
    }
  }

  void _onFrame(VisionFrame frame) {
    if (!mounted) return;
    final now = DateTime.now();
    final dt = now.difference(_lastFrameAt).inMicroseconds;
    _lastFrameAt = now;

    // 阈值在原生侧已生效，这里再过滤一次只为滑动条即时响应。
    final visible = frame.detections
        .where((d) => d.score >= _threshold)
        .toList(growable: false);

    _announcer.enabled = _speakEnabled;
    if (_speakEnabled) _announcer.onFrame(visible);

    setState(() {
      _detections = visible;
      _inferenceMs = frame.inferenceMs;
      if (frame.frameWidth > 0 && frame.frameHeight > 0) {
        // 原生回传的是**原始**帧尺寸（旋转之前），旋转角是把它转正所需角度。
        _frameSize = Size(
          frame.frameWidth.toDouble(),
          frame.frameHeight.toDouble(),
        );
      }
      if (dt > 0) {
        // 指数平滑：瞬时值抖动太大，看不出真实帧率。
        final inst = 1e6 / dt;
        _fps = _fps == 0 ? inst : _fps * 0.8 + inst * 0.2;
      }
    });
  }

  @override
  void dispose() {
    _diagTimer?.cancel();
    _sub?.cancel();
    _mock?.dispose();
    _platform.release();
    _speaker.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F13),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _statusBar(),
            Expanded(child: _previewArea()),
            _controlPanel(),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 预览区域

  Widget _previewArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewSize = Size(constraints.maxWidth, constraints.maxHeight);
        // DisplayFit 必须用**旋转后**的帧尺寸构造：归一化坐标在旋转之后
        // 才与屏幕方向一致。用错尺寸的表现是框被拉伸，且不报错。
        final rotated = rotatedFrameSize(_frameSize, _rotationDegrees);
        final fit = DisplayFit.contain(frame: rotated, view: viewSize);
        final mapped = mapDetectionsToScreen(
          detections: _detections,
          rotationDegrees: _rotationDegrees,
          fit: fit,
        );

        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (_mode == SourceMode.camera) const VisionPreview() else _mockScene(),
            // 叠加层不能拦截手势，否则下方的预览收不到事件。
            IgnorePointer(
              child: CustomPaint(
                painter: DetectionBoxPainter(
                  mapped: mapped,
                  showLabels: _showLabels,
                ),
              ),
            ),
            Positioned(left: 8, top: 8, child: _perfPanel()),
            Positioned(right: 8, top: 8, child: _fitDebug(fit)),
          ],
        );
      },
    );
  }

  /// 假数据模式下的背景：网格 + 十字线，让框的位移更容易看出来。
  Widget _mockScene() {
    return CustomPaint(painter: _GridPainter());
  }

  Widget _perfPanel() {
    final style = const TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
    );
    return _glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('FPS      ${_fps.toStringAsFixed(1)}', style: style),
          Text('推理     ${_inferenceMs.toStringAsFixed(1)} ms', style: style),
          Text('检测框   ${_detections.length}', style: style),
          // ---- 诊断计数：这几个数字直接指出链路卡在哪一环 ----
          // 「分析帧」为 0（红色）说明相机分析回路根本没跑起来；
          // 「最高分」低于阈值（橙色）说明模型没给出高分，问题在模型或输入；
          // 「跳过」非空则直接写出被跳过的原因。
          if (_diagnostics != null) ...<Widget>[
            Text(
              '分析帧   ${_diagnostics!.analyzedFrames}',
              style: style.copyWith(
                color: _diagnostics!.analyzedFrames == 0
                    ? Colors.redAccent
                    : Colors.white,
              ),
            ),
            if (_diagnostics!.analyzeErrors > 0)
              Text('分析错误 ${_diagnostics!.analyzeErrors}',
                  style: style.copyWith(color: Colors.redAccent)),
            Text(
              '最高分   ${_diagnostics!.frameMaxScore.toStringAsFixed(3)}',
              style: style.copyWith(
                color: _diagnostics!.frameMaxScore >= _threshold
                    ? Colors.greenAccent
                    : Colors.orangeAccent,
              ),
            ),
            if (_diagnostics!.skippedReason.isNotEmpty)
              Text(
                '跳过     ${_diagnostics!.skippedReason}',
                style: style.copyWith(color: Colors.orangeAccent, fontSize: 10),
              ),
          ],
          Text(
            '语音     ${_ttsLanguage ?? "未就绪"}',
            style: style.copyWith(
              color: _speaker.isCantonese ? Colors.greenAccent : Colors.orangeAccent,
            ),
          ),
        ],
      ),
    );
  }

  /// 显示这一帧的坐标假设。框画偏时**第一眼**要看这里：
  /// 帧尺寸或旋转角错了，映射必然错，而且不会有任何报错。
  Widget _fitDebug(DisplayFit fit) {
    final style = const TextStyle(color: Colors.white70, fontSize: 10);
    return _glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('帧 ${_frameSize.width.toInt()}x${_frameSize.height.toInt()}', style: style),
          Text('旋转 $_rotationDegrees°', style: style),
          Text('scale ${fit.scale.toStringAsFixed(3)}', style: style),
          Text('留边 ${fit.dx.toStringAsFixed(0)},${fit.dy.toStringAsFixed(0)}', style: style),
        ],
      ),
    );
  }

  Widget _glass({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
    );
  }

  // ------------------------------------------------------------- 状态条

  Widget _statusBar() {
    final color = _modelReady ? Colors.greenAccent : Colors.orangeAccent;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: const Color(0xFF161B22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                _modelReady ? Icons.check_circle : Icons.warning_amber,
                size: 16,
                color: color,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _status,
                  style: TextStyle(color: color, fontSize: 12),
                  // 不限制行数：状态里有失败原因时，截断会让人只看到「模型未加载」
                  // 而看不到「为什么」。之前用 maxLines: 2 就吃过这个亏。
                  softWrap: true,
                ),
              ),
            ],
          ),
          // 失败原因单独一块，**完整**显示，且长按可复制。
          // 理由：这类错误只在真机上出现，用户没有 logcat 可用；
          // 把完整文本摆在屏幕上、允许复制，比让他去翻日志现实得多。
          if (!_modelReady && _platform.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: GestureDetector(
                onLongPress: () async {
                  await Clipboard.setData(ClipboardData(text: _platform.error!));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('错误详情已复制'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    border: Border.all(color: color.withValues(alpha: 0.5)),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              '模型加载失败（长按复制）',
                              style: TextStyle(color: color, fontSize: 11,
                                               fontWeight: FontWeight.w600),
                            ),
                          ),
                          Icon(Icons.copy, size: 13, color: color),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        _platform.error!,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_modelReady && _modelNote != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                // 这条不是客套话：单类模型只会亮一个类别，
                // 不写清楚会被当成模型坏了。
                _modelNote!,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 11,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 控制面板

  Widget _controlPanel() {
    return Container(
      color: const Color(0xFF161B22),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text('阈值', style: TextStyle(color: Colors.white70, fontSize: 12)),
              Expanded(
                child: Slider(
                  value: _threshold,
                  min: 0.05,
                  max: 0.95,
                  divisions: 18,
                  label: _threshold.toStringAsFixed(2),
                  onChanged: (v) {
                    setState(() => _threshold = v);
                    _mock?.threshold = v;
                    // 原生侧也更新，否则低分框仍会跨通道传过来。
                    _platform.setThreshold(v);
                  },
                ),
              ),
              SizedBox(
                width: 42,
                child: Text(
                  _threshold.toStringAsFixed(2),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: SegmentedButton<SourceMode>(
                  segments: const <ButtonSegment<SourceMode>>[
                    ButtonSegment<SourceMode>(
                      value: SourceMode.camera,
                      label: Text('相机'),
                      icon: Icon(Icons.photo_camera, size: 16),
                    ),
                    ButtonSegment<SourceMode>(
                      value: SourceMode.mock,
                      label: Text('假数据'),
                      icon: Icon(Icons.grid_on, size: 16),
                    ),
                  ],
                  selected: <SourceMode>{_mode},
                  onSelectionChanged: (s) async {
                    final mode = s.first;
                    setState(() => _mode = mode);
                    _announcer.reset();
                    if (mode == SourceMode.camera) {
                      await _startCameraSource();
                    } else {
                      await _startMockSource();
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: _speakEnabled ? '关闭播报' : '开启播报',
                onPressed: () => setState(() => _speakEnabled = !_speakEnabled),
                icon: Icon(
                  _speakEnabled ? Icons.volume_up : Icons.volume_off,
                  color: _speakEnabled ? Colors.greenAccent : Colors.white38,
                ),
              ),
              IconButton(
                tooltip: _showLabels ? '隐藏标签' : '显示标签',
                onPressed: () => setState(() => _showLabels = !_showLabels),
                icon: Icon(
                  _showLabels ? Icons.label : Icons.label_off,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
          if (_announcer.history.isNotEmpty) _announceLog(),
        ],
      ),
    );
  }

  /// 播报决策日志。展示「为什么播/为什么跳过」，
  /// 是两级防抖真的在工作的直接证据。
  Widget _announceLog() {
    final recent = _announcer.history.reversed.take(3).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final a in recent)
            Text(
              '${a.at.hour.toString().padLeft(2, '0')}:'
              '${a.at.minute.toString().padLeft(2, '0')}:'
              '${a.at.second.toString().padLeft(2, '0')}  '
              '${a.label.nameZh}  ${a.reason}',
              style: TextStyle(
                fontSize: 11,
                color: a.reason.contains('跳过')
                    ? Colors.white38
                    : Colors.greenAccent,
              ),
            ),
        ],
      ),
    );
  }
}

/// 假数据模式的背景网格，让框的位移幅度可直接目视比较。
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFF23303C)
      ..strokeWidth = 1;
    const step = 40.0;
    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
    final c = Paint()
      ..color = const Color(0xFF2F4256)
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      c,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      c,
    );
    // 四角标记，用来核对框的边界夹紧是否正确
    final corner = Paint()
      ..color = const Color(0xFF3E566E)
      ..strokeWidth = 3;
    const l = 18.0;
    canvas.drawLine(Offset.zero, const Offset(l, 0), corner);
    canvas.drawLine(Offset.zero, const Offset(0, l), corner);
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width - l, size.height),
      corner,
    );
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width, size.height - l),
      corner,
    );
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      3,
      Paint()..color = const Color(0xFF4C6B87),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
