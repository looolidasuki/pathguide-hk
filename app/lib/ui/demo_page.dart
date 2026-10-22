import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../capture/text_read_result.dart';
import '../diag/status_log.dart';
import '../l10n/app_strings.dart';
import '../overlay/box_painter.dart';
import '../text/text_spotter.dart';
import '../tts/announcer.dart';
import '../tts/flutter_tts_speaker.dart';
import '../vision/detection.dart';
import '../vision/platform_vision.dart';
import '../vision/vision_preview.dart';
import '../vision/vision_session.dart';
import '../vision/vision_source.dart';

/// 領路通的主畫面——**整個 App 唯一的畫面**。
///
/// ## 這裡刻意沒有什麼
///
/// 這個畫面曾經是開發用的 demo 面板：資料來源切換（相機／假數據）、
/// 門檻滑條、FPS 與推理耗時、120 行的診斷面板、自適應除錯疊字、
/// 長按 4 秒看錯誤詳情。那些都是**開發者需要的**，不是使用者需要的。
///
/// 它們被移掉的理由不只是「不好看」，有兩條具體的：
///
/// 1. **門檻滑條對全盲使用者沒有意義。** 「0.42」不是他能判斷的東西，
///    調了會怎樣也無從得知。門檻該由 `kMinSpeakScore` 那套（有實測依據）
///    在程式裡決定，不該放在使用者手指下。
/// 2. **那個 debug 入口在盲用情境下從來沒有真正可用過。** 它的觸發方式是
///    **長按 4 秒**，而 TalkBack 開著時手勢會被攔截——也就是說，
///    全盲使用者打不開它，低視力使用者打開了也看不到它的意義。
///
/// ## 診斷資訊去哪裡了
///
/// 沒有消失，改成**寫出來**：`logcat` 加上一個可拉出的狀態檔
/// （見 [StatusLog]）。`VisionPlugin.kt` 裡那段計數器的註解記著它的來歷——
/// 「預覽正常但推理 0 次」當年只能靠反覆重新構建來猜。所以不能把它丟掉，
/// 只是不该畫在產品畫面上。狀態檔**永遠只留最近一份**，不留歷史（隱私）。
///
/// ## 輸出通道是語音，不是畫面
///
/// 障礙物與招牌都經由 TTS 出去。畫面留給低視力使用者與陪護者看，
/// 所以預覽、偵測框、標籤、狀態文字都還在——但它們是輔助，不是主要通道。
class DemoPage extends StatefulWidget {
  const DemoPage({super.key, this.speaker, this.sourceFactory, this.session});

  /// 語音輸出。預設是真的 TTS；測試注入假的。
  ///
  /// 有 [session] 時以 session 的為準（那是正式流程的路徑）。
  final Speaker? speaker;

  /// 建立檢測來源（測試用）。有 [session] 時以 session 的為準。
  final VisionSource Function()? sourceFactory;

  /// 相機與語音的共用持有者。正式流程由 `HomePage` 注入。
  final VisionSession? session;

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> with WidgetsBindingObserver {
  /// 相機與語音的共用持有者。
  ///
  /// 沒注入就自己建一個——這樣「直接開這一頁」（測試、或未來深層連結）
  /// 仍然可以運作，但正式流程由 `HomePage` 注入共用的那一個，
  /// 讓相機在兩個模式之間**保持開啟**（重啟要 1–2 秒）。
  late final VisionSession _session = widget.session ??
      VisionSession(
        speaker: widget.speaker,
        sourceFactory: widget.sourceFactory,
      );

  late final Speaker _speaker = _session.speaker;
  late final Announcer _announcer = _session.announcer;

  /// 機會式讀字。見 [TextSpotter] 的說明：只在偵測的空檔讀，
  /// 因為這台機器上「平行的第二條執行緒」救不了 CPU 滿載的問題。
  late final TextSpotter _spotter = TextSpotter(read: _readTextNow);

  StatusLog? _statusLog;
  Timer? _statusTimer;

  VisionSource? _source;
  StreamSubscription<VisionFrame>? _sub;

  List<Detection> _detections = const <Detection>[];

  /// 引導是否在跑。false 時畫面上才有「啟動引導」那顆按鈕。
  bool _guiding = false;

  /// 這次「停止引導」是不是因為切到背景造成的。
  ///
  /// 用來區分兩種停止：**使用者按了「結束引導」**（回來時不該自己開始）
  /// 與**系統把我們切到背景**（回來時應該恢復）。不分開的話，
  /// 只能二選一：要嘛使用者按了停、回來又被擅自啟動，
  /// 要嘛切出去再回來就一直是停的。
  bool _pausedByLifecycle = false;

  bool _speakEnabled = true;

  double _fps = 0;
  double _inferenceMs = 0;
  DateTime _lastFrameAt = DateTime.now();
  int _frames = 0;

  /// 狀態文字。**一律是可唸的完整句**，不是數字或代號——
  /// 這個專案曾把「按了沒反應」列為最嚴重的缺口，
  /// 所以任何狀態變化都要有一句話能說出來。
  String _status = '';


  /// 幀尺寸与旋转角都来自 [VisionSource]，不在 UI 里写常量。
  Size get _frameSize => _source?.frameSize ?? const Size(1280, 720);

  AppStrings get _s => AppStrings.current;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 切到背景就停：相機停了、`lastCapture` 也不再更新，
    // 繼續排程讀字只是白燒 CPU，而且回來時會唸出一段過期的招牌。
    if (state == AppLifecycleState.paused && _guiding) {
      _pausedByLifecycle = true;
      _stopGuidance(byLifecycle: true);
      return;
    }
    // ★ 回到前景必須**自己恢復**。
    //
    // 少了這一段，使用者切去別的地方再回來，畫面會停在「已停止引導」，
    // 而且沒有任何東西會把它叫回來——**看起來像 App 壞了**。
    // SystemChrome / Flutter 不會幫我們重啟相機，這件事只有這裡能做。
    if (state == AppLifecycleState.resumed &&
        _pausedByLifecycle &&
        !_guiding) {
      _pausedByLifecycle = false;
      unawaited(_startGuidance());
    }
  }

  Future<void> _bootstrap() async {
    await _initSpeaker();
    // 桌面與 Web 沒有這個原生插件；讓畫面留在「無法啟動引導」的狀態，
    // 而不是去呼叫一個不存在的通道然後噴例外。
    //
    // 有注入來源時（測試、或 `HomePage` 注入的共用 session）不受這個限制：
    // 那條路徑上根本沒有原生通道，判斷平台反而會讓它拒絕啟動。
    //
    // 注意：不能檢查 `session.source != null` —— 那在 `ensureCamera()`
    // 跑完之前一直是 null，於是這個守衛會把測試全部擋掉
    // （實際發生過：`initialized` 一直是 0）。注入 session 本身就是訊號。
    final hasInjectedSource =
        widget.sourceFactory != null || widget.session != null;
    if (!hasInjectedSource && !Platform.isAndroid && !Platform.isIOS) {
      if (mounted) setState(() => _status = _s.noCameraOnDevice);
      return;
    }
    await _startGuidance();
  }

  Future<void> _initSpeaker() async {
    final lang = await _speaker.initialize();
    if (!mounted) return;
    if (lang != null) {
      final sys = WidgetsBinding.instance.platformDispatcher.locale;
      final sysLang = sys.languageCode.toLowerCase();
      final used = lang.toLowerCase().replaceAll('_', '-');
      final matched = used == sysLang ||
          used.startsWith('$sysLang-') ||
          (sysLang == 'zh' &&
              (used.startsWith('zh') || used.startsWith('yue'))) ||
          (sysLang == 'yue' &&
              (used.startsWith('yue') || used.startsWith('zh-hk')));
      if (!matched) {
        // 語音包不匹配是**使用者必須知道**的事（他會聽到奇怪的語言），
        // 所以還是要唸；同時寫進 logcat 供事後診斷。
        _say(_s.ttsFallbackWarning(lang));
        debugPrint('[PathGuide] TTS fallback: $lang (system=${sys.toLanguageTag()})');
      }
    }
  }

  // ------------------------------------------------------------- 來源生命週期

  /// 啟動引導：取得相機、接上流與播報。
  ///
  /// 相機由 [_session] 持有並**跨模式存活**——所以從讀字模式切回來時
  /// 不必等相機重啟（真機實測 1–2 秒）。
  Future<void> _startGuidance() async {
    // **先出聲再做事。** 這一句是整個畫面最重要的回饋：
    // 使用者按了之後若安靜兩秒，他不知道是按失敗還是還在忙。
    _say(_s.starting);
    if (mounted) setState(() => _status = _s.starting);

    _announcer.reset();
    _spotter.reset();

    final status = await _session.ensureCamera();
    if (!mounted) return;

    if (!status.ok) {
      setState(() {
        _guiding = false;
        _status = status.message;
      });
      // 失敗一定要出聲，否則使用者只會反覆按同一顆按鈕。
      _say(status.message);
      return;
    }

    final source = _session.source!;
    _source = source;

    // 先接流再啟用畫面：否则首帧可能丢。
    await _sub?.cancel();
    _sub = source.frames.listen(
      _onFrame,
      onError: (Object e) {
        if (mounted) setState(() => _status = _s.inferenceStreamError(e));
      },
    );

    setState(() {
      _guiding = true;
      _status = _s.guiding;
    });

    _startStatusLog(source: source);
    if (_speakEnabled) _say(_s.guiding);
  }

  /// 停止引導：拆掉相機、停止語音、清掉畫面。
  ///
  /// `byLifecycle` 區分「系統切到背景」與「使用者按了結束引導」——
  /// 只有前者會在下一次回到前景時自動恢復（見 [didChangeAppLifecycleState]）。
  /// 使用者自己按了停，回來時**不該**被擅自啟動。
  ///
  /// ## ★ 為什麼這裡**不** await `cancel()` 與 `dispose()`
  ///
  /// 這是本方法最重要的一點，而且是被測試抓出來的：
  ///
  /// `StreamSubscription.cancel()` 與 `VisionSource.dispose()` 都回傳 Future，
  /// 但它們**沒有保證會完成**。實際踩到的情況是 `cancel()` 永遠不回來，
  /// 於是整個方法卡在第一行——按鈕看起來完全沒作用，沒有錯誤、沒有訊息，
  /// 畫面就停在「引導中」。那正是本專案列為最嚴重的那類缺陷。
  ///
  /// 所以拆解順序刻意改成：
  ///   1. 先讓**介面立刻回到未啟動狀態**（同步，不依賴任何 Future）
  ///   2. 再在背景把資源收掉，失敗只寫診斷
  ///
  /// 收音機不會因為清理慢半拍而繼續運作：`_source` 一設成 null，
  /// `_onFrame` 的來源就沒了，而且 `_guiding` 已經變 false。
  void _stopGuidance({bool byLifecycle = false}) {
    final sub = _sub;
    _sub = null;
    _source = null;

    // 使用者自己按的「結束引導」要清掉恢復意圖；切背景造成的停則保留它，
    // 等 [didChangeAppLifecycleState] 在回到前景時恢復。
    if (!byLifecycle) _pausedByLifecycle = false;

    _announcer.reset();
    _spotter.reset();
    _statusTimer?.cancel();
    _statusTimer = null;

    if (mounted) {
      setState(() {
        _guiding = false;
        _detections = const <Detection>[];
        _fps = 0;
        _inferenceMs = 0;
        _frames = 0;
        _status = _s.guidanceStopped;
      });
    }
    _say(_s.guidanceStopped);

    // 背景清理。`unawaited` 是刻意的——見上面的說明。
    unawaited(() async {
      try {
        await sub?.cancel();
      } catch (e) {
        debugPrint('[PathGuide] 取消幀訂閱失敗（已忽略）：$e');
      }
      // ★ **不要 dispose 來源。**
      //
      // 相機由 [VisionSession] 持有、**跨模式存活**。在這裡 dispose 會把
      // 讀字模式的相機一起弄死，而那一邊完全不知道發生了什麼——
      // 表現是「從引導切回讀字後就再也讀不到」。
      //
      // 結束引導只該做兩件事：**退訂**（不再收幀）與**停語音**。
      // 真正的釋放由 `VisionSession.releaseCamera()` 負責（離開整個 App 時）。
      try {
        await _speaker.stop();
      } catch (e) {
        debugPrint('[PathGuide] 停止語音失敗（已忽略）：$e');
      }
    }());
  }

  /// 狀態檔：把診斷數字寫出來，而不是畫在畫面上。
  void _startStatusLog({required VisionSource source}) {
    if (source is! PlatformVision) return;

    // 目錄由原生提供（`modelDir`）。不用 path_provider：它會拉進
    // objective_c，那是本倉庫的硬約束——路徑含空格會讓 build hook 失敗。
    unawaited(() async {
      try {
        final dir = await source.appFilesDir();
        if (dir == null || !mounted) return;
        _statusLog = StatusLog(dir: dir);
        _writeStatus(); // 立刻寫第一份，別等第一個週期。
        _statusTimer = Timer.periodic(
          const Duration(seconds: 5),
          (_) => _writeStatus(),
        );
      } catch (e) {
        debugPrint('[PathGuide] 狀態檔不可用（已忽略）：$e');
      }
    }());
  }

  void _writeStatus() {
    final log = _statusLog;
    if (log == null) return;
    unawaited(log.write(<String, Object?>{
      'frames': _frames,
      'fps': _fps,
      'inferenceMs': _inferenceMs,
      'detections': _detections.length,
      'guiding': _guiding,
      'voice': _speakEnabled,
      // 機會式讀字的狀態。這幾個數字決定「招牌多久被唸一次」，
      // 而那是真機上唯一能回答「有沒有在搶 CPU」的證據。
      'spotAttempts': _spotter.attempts,
      'spotEmptyStreak': _spotter.consecutiveEmpty,
      'spotIntervalMs': _spotter.currentInterval.inMilliseconds,
      'spotLastReason': _spotter.lastReason,
      'spotLastText': _spotter.lastText,
      // ★ 以下三項是為了分開「沒讀到字」與「讀到卻沒出聲」。
      //
      // 沒有它們時，這兩種情況在狀態檔裡長得**一模一樣**（都只是沒聲音），
      // 於是只能靠猜。而真機上實際發生的正是後者：OCR 讀到了字，
      // 卻被播報讓位規則丟掉。
      'spotLastElements': _lastReadElements,
      'spotSpoken': _spokenCount,
      'spotDeferred': _spotter.deferrals,
      // 語音若整個 session 都發不出聲，這裡會有原因。
      'ttsError': switch (_speaker) {
        final FlutterTtsSpeaker s => s.lastSpeechError,
        _ => null,
      },
    }));
  }

  /// 最近一次 OCR 讀到的元素數。0 表示真的沒看到字。
  int _lastReadElements = 0;

  /// 實際唸出去的招牌次數。
  int _spokenCount = 0;

  /// 讀一幀的文字。機會式排程的**唯一**入口。
  Future<TextReadResult> _readTextNow() async {
    final source = _source;
    if (source is! PlatformVision || !source.supportsTextReading) {
      // 平台沒實作（iOS）或相機沒起來。回一個明確的失敗，
      // 讓 TextSpotter 的診斷字串說得出原因，而不是沉默。
      return TextReadResult.fail('此平台或此來源不支援讀字');
    }
    final r = await source.readText();
    // 記下元素數：0 表示「真的沒看到字」，>0 而最後沒出聲就是被讓位丟掉。
    _lastReadElements = r.elements.length;
    return r;
  }

  // ------------------------------------------------------------- 幀處理

  void _onFrame(VisionFrame frame) {
    if (!mounted) return;
    final now = DateTime.now();
    final dt = now.difference(_lastFrameAt).inMicroseconds;
    _lastFrameAt = now;
    _frames++;

    // **不再按阈值过滤**：阈值已在来源内部生效（原生侧丢弃低分框）。
    // 两处各过滤一次时，不一致的表现是「框数对不上」，且不报错。
    _announcer.enabled = _speakEnabled;
    if (_speakEnabled) _announcer.onFrame(frame.detections);

    // 機會式讀字：**只有在偵測的空檔才做**，所以不 await——
    // 在這裡 await 就是把它變成「與偵測並行」，那正是要避免的事。
    if (_speakEnabled) _feedSpotter(frame.detections);

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

  void _feedSpotter(List<Detection> detections) {
    if (!_spotter.shouldReadNow(detections)) return;
    unawaited(() async {
      final spot = await _spotter.tick(detections);
      if (spot == null || !spot.hasText || !mounted) return;

      // ★ 逐句唸，而不是整段一次丟出去。
      //
      // 兩個理由，都是真機回報的問題：
      //  1. 整段一次唸**沒有任何停頓**，使用者分不出哪裡是一個資訊的結束
      //     （「沒有斷句沒有間隔」）。
      //  2. 菜單／商場指南上百字一次唸要好幾十秒，期間所有障礙物播報被擋住。
      //
      // `flutter_tts` 的佇列模式（`setQueueMode(0)`）會讓這些片段依序唸完、
      // 自然停頓，而且任何一句之後都能被障礙物播報插進來。
      final chunks = TextSpotter.capTotal(TextSpotter.toChunks(spot.text));
      if (chunks.isEmpty) return;

      // ★ 安全閥：招牌**永遠不能**蓋掉障礙物播報。障礙物正在出聲時整批讓位。
      if (!_announcer.beginTextBatch()) {
        _spotter.defer();
        return;
      }

      // 第一句要加「招牌寫著」；後續句子不加——否則每一句前面都重複一次，
      // 聽起來很吵，而且會拉長總時長。
      final prefix = _s.readSignPrefix;
      var said = 0;
      for (var i = 0; i < chunks.length; i++) {
        final text = i == 0 ? '$prefix${chunks[i]}' : chunks[i];
        if (!_announcer.enqueueText(text)) break; // 被讓位就停，剩下的不唸
        said++;
      }

      if (said > 0) {
        _spokenCount += said;
        _announcer.endTextBatch();
        _spotter.markSpoken();
      } else {
        _spotter.defer();
      }
    }());
  }

  // ------------------------------------------------------------- 採集
  //
  // 產品畫面上**沒有**採集入口。幀採集（[FrameSampler]、`PlatformVision.captureFrame`）
  // 仍然保留在程式庫裡給資料流水線與測試用，但它不再是一顆使用者按得到的按鈕。
  //
  // 移除理由（與 `docs/UPSTREAM-MERGE-ASSESSMENT.md` §6.2 是同一條）：
  // 它與「結束引導」並排，是引導畫面上最容易誤觸的一顆，而它做的事
  // ——把畫面留存下來——並不是使用者在**走路時**要做的決定。
  // 引導畫面因此從 4 個控件降到 3 個。

  /// 直接對喇叭說話，**繞過** [Announcer] 的冷卻。
  ///
  /// 用在「使用者剛按了什麼」這類即時回饋上：那些不是障礙物播報，
  /// 不該被障礙物的冷卻壓掉，也不該佔用它的歷史。
  void _say(String text) {
    if (text.isEmpty) return;
    _speaker.speak(text).ignore();
  }

  // ------------------------------------------------------------- 畫面

  @override
  void dispose() {
    _statusTimer?.cancel();
    _sub?.cancel();
    // ★ 不 dispose 來源：相機由 [VisionSession] 持有、跨模式存活。
    // 這裡 dispose 會讓讀字模式跟著壞掉（而它完全不知道發生什麼事）。
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ------------------------------------------------------------- 畫面

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F13),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _header(),
            Expanded(child: _previewArea()),
            _actionArea(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: <Widget>[
          // 標題不是互動元素，用 ExcludeSemantics 讓 TalkBack 不為它停一站——
          // 這張畫面只有兩個可操作項，多一站就是多一次滑動。
          ExcludeSemantics(
            child: Text(
              _s.appTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

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

        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (_guiding) const VisionPreview() else _idleScene(),
            // 叠加层不能拦截手势，否则下方的预览收不到事件。
            IgnorePointer(
              child: CustomPaint(
                painter: DetectionBoxPainter(
                  mapped: mapped,
                  showLabels: true,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 尚未啟動引導時的背景。刻意保持安靜：只有一句話，
  /// 不做任何動畫或裝飾——低視力使用者需要的是能讀的字，不是效果。
  Widget _idleScene() {
    return ColoredBox(
      color: const Color(0xFF11161C),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _status.isEmpty ? _s.cameraNotStarted : _status,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 16,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }

  /// 底部動作區。
  ///
  /// 引導中時兩個可操作項（語音、結束引導），未啟動時只有一個
  /// （啟動引導）——因為語音開關在沒有相機時沒有意義，
  /// 而「結束引導」在沒開始時按下只會回一句「請先啟動引導」。
  Widget _actionArea() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF161B22),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_guiding) _statusLine() else _startButton(),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(child: _voiceButton()),
              if (_guiding) ...<Widget>[
                const SizedBox(width: 8),
                Expanded(child: _stopButton()),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 狀態列。這是**低視力使用者與陪護者**看的那一句；
  /// 全盲使用者聽的是同一件事的語音版本。
  Widget _statusLine() {
    final text = _status.isEmpty ? _s.guiding : _status;
    return Semantics(
      liveRegion: true,
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
      ),
    );
  }

  /// 主按鈕。**標籤即結果**——不用「開始」這種模糊詞。
  ///
  /// 高度刻意做大（56）：這是這張畫面上唯一的強調動作，
  /// 而低視力使用者的觸控精確度通常較差。
  Widget _startButton() {
    return SizedBox(
      height: 56,
      child: FilledButton.icon(
        onPressed: _guiding ? null : _startGuidance,
        icon: const Icon(Icons.play_arrow, size: 26),
        label: Text(
          _s.startGuidance,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  /// 語音開關。label 是**動作 + 結果**（「開啟語音」），不是狀態——
  /// 螢幕閱讀器唸的是「按下去會發生什麼」。
  Widget _voiceButton() {
    return SizedBox(
      height: 48,
      child: OutlinedButton.icon(
        onPressed: () {
          setState(() => _speakEnabled = !_speakEnabled);
          _announcer.enabled = _speakEnabled;
          if (!_speakEnabled) {
            // 關掉語音時必須立刻停掉正在說的那句，否則使用者按了「關閉」
            // 卻還聽到聲音，會以為按鈕沒作用。
            unawaited(_speaker.stop());
          }
          _say(_speakEnabled ? _s.voiceOn : _s.voiceOff);
        },
        icon: Icon(
          _speakEnabled ? Icons.volume_up : Icons.volume_off,
          size: 22,
        ),
        label: Text(_speakEnabled ? _s.disableVoice : _s.enableVoice),
      ),
    );
  }

  Widget _stopButton() {
    return SizedBox(
      height: 48,
      child: OutlinedButton.icon(
        onPressed: _stopGuidance,
        icon: const Icon(Icons.stop, size: 22),
        label: Text(_s.stopGuidance),
      ),
    );
  }
}
