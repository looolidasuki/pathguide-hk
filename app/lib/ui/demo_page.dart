import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../overlay/box_painter.dart';
import '../tts/announcer.dart';
import '../tts/flutter_tts_speaker.dart';
import '../vision/detection.dart';
import '../vision/mock_vision_source.dart';
import '../vision/platform_vision.dart';
import '../vision/vision_preview.dart';
import '../vision/vision_source.dart';

/// 界面可切换的检测来源种类。
///
/// 这个枚举只用来渲染「相机 / 假数据」两个按钮，**不参与运行期分派**——
/// 分派由 [_DemoPageState._makeSource] 完成，之后 UI 只持有一个
/// [VisionSource]。曾经 UI 里通篇是 `_platform.xxx` 与 `_mock?.xxx` 两套
/// 并行分支，换平台要把每个分支抄一遍，且两个实现的行为无一致性保证。
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
  final FlutterTtsSpeaker _speaker = FlutterTtsSpeaker();
  late final Announcer _announcer = Announcer(speaker: _speaker);

  StreamSubscription<VisionFrame>? _sub;

  SourceMode _mode = SourceMode.camera;

  /// **界面唯一持有的检测来源。**
  ///
  /// 相机与假数据都是 [VisionSource]，UI 不再需要知道用的是哪一个
  /// （只有渲染预览时按 [_mode] 决定显示相机视图还是网格背景）。
  VisionSource? _source;

  double _threshold = 0.30;
  bool _speakEnabled = true;
  bool _showLabels = true;

  List<Detection> _detections = const <Detection>[];

  double _inferenceMs = 0;
  double _fps = 0;
  DateTime _lastFrameAt = DateTime.now();

  String _status = '正在初始化…';
  String? _statusError;

  /// 本次初始化是否成功。用于状态栏配色与错误面板显示。
  bool _sourceReady = false;
  String? _ttsLanguage;

  /// 原生侧诊断快照，定时轮询后显示在 HUD 上。
  /// 假数据源的 [VisionSource.diagnostics] 返回 null，此时面板自动隐藏。
  VisionDiagnostics? _diagnostics;
  Timer? _diagTimer;

  /// 帧尺寸与旋转角都来自 [VisionSource]，不在 UI 里写常量。
  ///
  /// `frameSize` 已经是**旋转之后**的尺寸，可直接用于 `DisplayFit`。
  Size get _frameSize =>
      _source?.frameSize ?? const Size(1280, 720);

  int get _rotationDegrees => _source?.rotationDegrees ?? 0;

  /// 最近一次布局算出的 fit 与屏幕矩形，**只给 [_logHud] 用**。
  ///
  /// 为什么要在 build 里顺手记下来：判断「屏幕上到底画没画框」需要的是
  /// **映射之后的屏幕矩形**，而它只在 build 里算得出来。这里只做赋值、
  /// 不触发重建，因此不改变 build 的语义。
  DisplayFit? _lastFit;
  List<({Detection detection, Rect rect})> _lastMapped =
      const <({Detection detection, Rect rect})>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    await _initSpeaker();
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await _switchSource(SourceMode.camera);
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

  /// 按种类构造一个检测来源。
  ///
  /// 这是**唯一**出现具体实现类名的地方。新增平台（iOS）或新增来源种类时，
  /// 只改这一处，UI 其余部分不动。
  VisionSource _makeSource(SourceMode mode) {
    switch (mode) {
      case SourceMode.camera:
        return PlatformVision();
      case SourceMode.mock:
        // 假源的原始帧尺寸与旋转角与相机实现保持一致，
        // 这样「假数据下框画对了」才能推出「相机下也会画对」。
        return MockVisionSource(
          frameSize: const Size(1280, 720),
          rotationDegrees: 90,
          threshold: _threshold,
        );
    }
  }

  /// 切换检测来源：停旧的、起新的、重接流与诊断轮询。
  Future<void> _switchSource(SourceMode mode) async {
    await _sub?.cancel();
    _diagTimer?.cancel();
    _announcer.reset();

    final old = _source;
    await old?.dispose();

    final source = _makeSource(mode);
    _source = source;

    if (mounted) {
      setState(() {
        _mode = mode;
        _detections = const <Detection>[];
        _diagnostics = null;
        _status = '正在初始化（${source.displayName}）…';
        _statusError = null;
        _sourceReady = false;
      });
    }

    // 先接流再初始化：否则首帧可能丢。
    _sub = source.frames.listen(_onFrame, onError: (Object e) {
      if (mounted) setState(() => _status = '推理流出错：$e');
    });
    final status = await source.initialize();

    // ★ 阈值必须在 initialize 之后写。
    // PlatformVision 的 threshold setter 会把值推给原生；若在 initialize 前写，
    // 原生相机尚未启动，推送会被静默忽略——于是「初始阈值」实际没生效，
    // 要等用户拖一次滑动条才对上。这类时序错误不报错。
    source.threshold = _threshold;

    if (!mounted) return;
    setState(() {
      _sourceReady = status.ok;
      _status = status.message;
      _statusError = status.error;
    });

    // 诊断轮询。假数据源返回 null，面板会自动隐藏——
    // 不会像以前那样在假数据模式下仍去轮询一个不存在的原生设备。
    _diagTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final d = await source.diagnostics();
      if (mounted && d != null) setState(() => _diagnostics = d);
      _logHud();
    });
  }

  /// 把 HUD 上的关键数字同步打一行到 logcat（仅 Debug 构建）。
  ///
  /// ## 为什么要有这一行
  ///
  /// 诊断信息原本只画在屏幕上，于是「真机验证」只能靠人眼看屏幕复述数字：
  /// 无法无人值守、无法留证、也无法在远程排查时比对。
  /// 截图虽然能留证，但要读屏幕上的小字仍需人工（或 OCR）。
  ///
  /// 这一行让整条链路变成**可被程序读取**的：帧率、耗时至 UI 的检测框数、
  /// 原生分析帧数、最高分、无效值分类、几何输入、张量布局全在同一行里。
  /// 于是「跑一次真机」= 装包 + 抓 logcat，不需要任何人盯屏幕。
  ///
  /// 字段名刻意用 ASCII，方便 grep：
  ///
  ///     HUD fps=.. inf=..ms det=.. analyzed=.. nativeDet=.. maxScore=.. ...
  ///
  /// 其中 `boxes=` 是**映射之后的屏幕矩形**（最多 3 个），
  /// `paint=` 是画布会实际画出的框数——它按 `DetectionBoxPainter` 的规则
  /// （`rect.width/height < 2` 视为噪点而跳过）算出来。
  /// 这一项直接回答最初那句「HUD 有数字、屏幕上一个框都没有」：
  /// `det>0` 而 `paint=0` 就说明矩形退化或被裁掉，而不是「类别没对上」。
  void _logHud() {
    if (!kDebugMode) return;
    final d = _diagnostics;
    final reasons = d == null || d.invalidByReason.isEmpty
        ? '-'
        : d.invalidByReason.entries
            .map((e) => '${e.key}=${e.value}')
            .join(',');
    final paint = _lastMapped
        .where((m) => m.rect.width >= 2 && m.rect.height >= 2)
        .length;
    final boxes = _lastMapped
        .take(3)
        .map((m) => '(${m.rect.left.round()},${m.rect.top.round()},'
            '${m.rect.width.round()}x${m.rect.height.round()})')
        .join(' ');
    debugPrint(
      'HUD fps=${_fps.toStringAsFixed(1)} '
      'inf=${_inferenceMs.toStringAsFixed(1)}ms '
      'det=${_detections.length} '
      'paint=$paint '
      'speakMin=${kMinSpeakScore.toStringAsFixed(2)} '
      'boxes=[$boxes] '
      'analyzed=${d?.analyzedFrames ?? -1} '
      'nativeDet=${d?.detectionCount ?? -1} '
      'maxScore=${(d?.frameMaxScore ?? 0).toStringAsFixed(3)} '
      'invalid=${d?.invalidDetections ?? -1} '
      'reasons=$reasons '
      'fit=${_lastFit?.scale.toStringAsFixed(3) ?? '-'} '
      'frame=${d?.frameWidth ?? 0}x${d?.frameHeight ?? 0} '
      'rot=$_rotationDegrees '
      'src=${_frameSize.width.toInt()}x${_frameSize.height.toInt()} '
      'decode=${d?.decodeStats ?? '-'} '
      'skip=${(d?.skippedReason.isNotEmpty ?? false) ? d!.skippedReason : '-'} '
      'err=${(d?.analyzeError.isNotEmpty ?? false) ? d!.analyzeError : '-'}',
    );
  }

  void _onFrame(VisionFrame frame) {
    if (!mounted) return;
    final now = DateTime.now();
    final dt = now.difference(_lastFrameAt).inMicroseconds;
    _lastFrameAt = now;

    // **不再按阈值过滤**：阈值已在来源内部生效（原生侧丢弃低分框，
    // 假源同样按 threshold 过滤）。两处各过滤一次时，不一致的表现是
    // 「滑动条不生效」或「框数对不上」，且不报错。
    _announcer.enabled = _speakEnabled;
    if (_speakEnabled) _announcer.onFrame(frame.detections);

    setState(() {
      _detections = frame.detections;
      _inferenceMs = frame.inferenceMs;
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
    _source?.dispose();
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
        // [VisionSource.frameSize] 与检测框坐标同属一个**已转正**的坐标系
        // （旋转已由原生在采样时逐像素完成），所以这里直接用，
        // 映射时也不再施加旋转——见 [mapDetectionsToScreen] 的说明。
        final fit = DisplayFit.contain(frame: _frameSize, view: viewSize);
        final mapped = mapDetectionsToScreen(
          detections: _detections,
          fit: fit,
        );
        // 供 _logHud 报告「映射后的屏幕矩形」——只赋值，不触发重建。
        _lastFit = fit;
        _lastMapped = mapped;

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

  /// 几何一致性检查：**分析流尺寸**与**预览流尺寸**是否一致。
  ///
  /// ## 为什么需要这条
  ///
  /// 预览由 CameraX 自己缩放显示，而框的位置由 Dart 用分析流的尺寸算出。
  /// 两条流的宽高比若不同，画面与框就会**系统性错位**——而且不报错。
  /// 这是「预览和框对不上」这类问题最难查的一种成因，所以显式检查。
  ///
  /// 返回 null 表示一致（或无数据可判）。
  String? _geometryWarning() {
    final d = _diagnostics;
    if (d == null || d.frameWidth <= 0 || d.frameHeight <= 0) return null;
    // d.frameWidth/Height 是**原始**帧尺寸；来源报的 frameSize 已是旋转后，
    // 所以比较时把来源的也转回原始尺寸。
    final raw = rotatedFrameSize(_frameSize, _rotationDegrees);
    final same = raw.width.round() == d.frameWidth &&
        raw.height.round() == d.frameHeight;
    if (same) return null;
    return '几何不一致：画框用 ${raw.width.round()}x${raw.height.round()}，'
        '分析流实际 ${d.frameWidth}x${d.frameHeight} → 框会整体偏移';
  }

  Widget _perfPanel() {
    final style = const TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
    );
    final geo = _geometryWarning();
    return _glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('FPS      ${_fps.toStringAsFixed(1)}', style: style),
          Text('推理     ${_inferenceMs.toStringAsFixed(1)} ms', style: style),
          Text('检测框   ${_detections.length}', style: style),
          if (geo != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: SizedBox(
                width: 210,
                child: SelectableText(
                  geo,
                  style: style.copyWith(color: Colors.redAccent, fontSize: 9),
                ),
              ),
            ),
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
              '分数     ${_diagnostics!.frameMinScore.toStringAsFixed(2)}'
              '~${_diagnostics!.frameMaxScore.toStringAsFixed(2)}',
              style: style.copyWith(
                // 模型最后一层是 sigmoid，分数必在 [0,1]。超过 1 就是解码错了。
                color: _diagnostics!.frameMaxScore > 1.0
                    ? Colors.redAccent
                    : (_diagnostics!.frameMaxScore >= _threshold
                        ? Colors.greenAccent
                        : Colors.orangeAccent),
              ),
            ),
            if (_diagnostics!.invalidDetections > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: SizedBox(
                  width: 200,
                  child: SelectableText(
                    // 分类计数：三种原因指向完全不同的故障，只有总数时无法区分。
                    '无效 ${_diagnostics!.invalidDetections}\n'
                    '${_invalidReasonText()}\n'
                    '${_diagnostics!.invalidSample}',
                    style: style.copyWith(color: Colors.redAccent, fontSize: 9),
                  ),
                ),
              ),
            // 任何诊断都显示时，一并显示解码统计（raw vs decoded 的范围对照）。
            if (_diagnostics!.decodeStats.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: SizedBox(
                  width: 210,
                  child: SelectableText(
                    _diagnostics!.decodeStats,
                    style: style.copyWith(color: Colors.lightGreenAccent, fontSize: 8),
                  ),
                ),
              ),
            // 输入/输出缓冲的真实内容。只在出现无效检测时显示，避免平时刷屏。
            if (_diagnostics!.invalidDetections > 0) ...<Widget>[
              if (_diagnostics!.inputStats.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: SizedBox(
                    width: 200,
                    child: SelectableText(
                      '输入 ${_diagnostics!.inputStats}',
                      style: style.copyWith(color: Colors.cyan, fontSize: 9),
                    ),
                  ),
                ),
              if (_diagnostics!.outputStats.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: SizedBox(
                    width: 200,
                    child: SelectableText(
                      '输出 ${_diagnostics!.outputStats}',
                      style: style.copyWith(color: Colors.cyan, fontSize: 9),
                    ),
                  ),
                ),
            ],
            // 缓冲指针快照：一直显示。异常发生在推理中途时，
            // 只有初始化时记下的这份数值还能看。
            if (_diagnostics!.bufferState.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: SizedBox(
                  width: 200,
                  child: SelectableText(
                    _diagnostics!.bufferState,
                    style: style.copyWith(color: Colors.cyanAccent, fontSize: 8),
                  ),
                ),
              ),
            if (_diagnostics!.analyzeErrors > 0 &&
                _diagnostics!.analyzeError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: SizedBox(
                  width: 190,
                  child: SelectableText(
                    // 异常的完整类型与消息直接摆在屏幕上。
                    // 真机上没有 logcat 可用，这行文字是唯一的线索来源。
                    _diagnostics!.analyzeError,
                    style: style.copyWith(color: Colors.redAccent, fontSize: 9),
                  ),
                ),
              ),
            if (_diagnostics!.skippedReason.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: SizedBox(
                  width: 190,
                  child: SelectableText(
                    _diagnostics!.skippedReason,
                    style: style.copyWith(color: Colors.orangeAccent, fontSize: 9),
                  ),
                ),
              ),
          ],
          Text(
            '语音     ${_ttsLanguage ?? "未就绪"}',
            style: style.copyWith(
              color: _speaker.isCantonese ? Colors.greenAccent : Colors.orangeAccent,
            ),
          ),
          // 两个阈值分开展示，因为它们管的事不同：
          // 上面那根滑条决定**画不画**，这一行是**说不说**的下限。
          // 不写出来，用户会以为「滑条拉低了怎么还不念」是坏了。
          Text(
            '播报门槛 ≥ ${kMinSpeakScore.toStringAsFixed(2)}（低分只画框）',
            style: style.copyWith(color: Colors.white70),
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

  /// 把无效检测的分类计数渲染成一行短文本，例如 `score_out_of_range=8400`。
  ///
  /// 单独成方法而不是写成嵌套插值：嵌套引号极易出错，而这里又只是字符串拼接。
  String _invalidReasonText() {
    final m = _diagnostics?.invalidByReason ?? const <String, int>{};
    if (m.isEmpty) return '(未分类)';
    return m.entries.map((e) => '${e.key}=${e.value}').join(' ');
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
    final color = _sourceReady ? Colors.greenAccent : Colors.orangeAccent;
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
                _sourceReady ? Icons.check_circle : Icons.warning_amber,
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
          if (!_sourceReady && _statusError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: GestureDetector(
                onLongPress: () async {
                  await Clipboard.setData(ClipboardData(text: _statusError!));
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
                              '${_source?.displayName ?? "来源"}初始化失败（长按复制）',
                              style: TextStyle(color: color, fontSize: 11,
                                               fontWeight: FontWeight.w600),
                            ),
                          ),
                          Icon(Icons.copy, size: 13, color: color),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        _statusError!,
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
              const Text('显示阈值',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
              Expanded(
                child: Slider(
                  value: _threshold,
                  min: 0.05,
                  max: 0.95,
                  divisions: 18,
                  label: _threshold.toStringAsFixed(2),
                  onChanged: (v) {
                    setState(() => _threshold = v);
                    // 只写一处：来源自己负责把阈值应用到它的过滤逻辑
                    // （相机推给原生、假源在 Dart 内过滤）。
                    // UI 不再各写一份——两处各写是「滑动条不生效」的成因。
                    _source?.threshold = v;
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
                    // 不再按种类写两个分支去调各自的启动函数：
                    // 切换来源统一走 _switchSource，它内部同等地处理
                    // 「停旧的、起新的、重接流与诊断」。
                    if (s.first == _mode) return;
                    await _switchSource(s.first);
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
