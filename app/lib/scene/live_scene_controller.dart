import 'dart:async';

import 'package:flutter/foundation.dart';

import '../tts/announcer.dart';
import '../tts/speech_coordinator.dart';
import 'scene_backend.dart';
import 'live_scene_signal.dart';

/// Change-triggered cloud descriptions borrowed from the active camera.
/// No timer uploads, camera ownership, image retention or paid retries.
enum SceneModeState { off, observing, analysing, speaking, waiting, restricted }

class LiveSceneController extends ChangeNotifier {
  LiveSceneController({
    required this.capture,
    required this.backend,
    required this.speaker,
    DateTime Function()? clock,
    this.cooldown = const Duration(seconds: 3),
    this.stableFor = const Duration(milliseconds: 250),
    this.maxSessionAttempts = 100,
    this.speechEnvironment,
  }) : _clock = clock ?? DateTime.now {
    _historyScope = backend is FirebaseSceneBackend
        ? (backend as FirebaseSceneBackend).diagnosticScope
        : null;
    if (_historyScope != _savedScope) {
      _savedReports.clear();
      _savedScope = _historyScope;
    }
    if (_historyScope != null) _reports.addAll(_savedReports);
  }
  final Future<Uint8List?> Function() capture;
  final SceneBackend backend;
  final Speaker speaker;
  final DateTime Function() _clock;
  final Duration cooldown, stableFor;
  final int maxSessionAttempts;
  final String Function()? speechEnvironment;
  static String? _savedScope;
  static final Map<String, String> _savedReports = {};
  String? _historyScope;
  final Map<String, String> _reports = {};
  void _archive() {
    if (lastRequestId == null) return;
    _reports.remove(lastRequestId);
    _reports[lastRequestId!] = _currentDiagnostics;
    while (_reports.length > 3) {
      _reports.remove(_reports.keys.first);
    }
    if (_historyScope != null &&
        backend is FirebaseSceneBackend &&
        _savedScope == _historyScope &&
        (backend as FirebaseSceneBackend).diagnosticScope == _historyScope) {
      _savedReports
        ..clear()
        ..addAll(_reports);
    }
  }

  bool available = false,
      automatic = false,
      busy = false,
      speaking = false,
      _disposed = false;
  int attempts = 0, _generation = 0;
  String status = '場景分析未啟用', failure = '';
  String? preparationCode;
  String? text;
  SceneMetrics? metrics;
  double estimatedUsd = 0;
  bool usageUnknown = false;
  LiveSceneSignal? _latest, _stable, _baseline, _evidence;
  DateTime? _received, _stableSince, _lastAttempt;
  String? _previousFullText;
  Timer? _freshness, _expiry, _speechExpiry;
  bool restricted = false, _checkingStatus = false;
  String? stopReason, rejectionDetail;
  List<String> _remoteReports = const [];
  Future<void> refreshStatus() async {
    if (_disposed || _checkingStatus || backend is! SceneStatusBackend) return;
    _checkingStatus = true;
    final job = _job;
    _notify();
    try {
      final result = await (backend as SceneStatusBackend).readStatus().timeout(
        const Duration(seconds: 14),
      );
      if (_disposed || job != _job) return;
      serverLimits = result.limits ?? serverLimits;
      _remoteReports = result.recentReports;
      if (result.stopReason != null) {
        stopReason = result.stopReason;
        restricted = true;
        phase = '受限待處理';
        status = sceneStopMessage(stopReason, serverLimits);
        _setNotice('restricted', '場景試驗已受限制，暫停新分析。');
      }
      _record('已讀取伺服器數值及狀態；沒有取相或呼叫模型');
    } catch (_) {
      if (!_disposed) _record('未能讀取伺服器測試狀態；沒有取相或呼叫模型');
    } finally {
      _checkingStatus = false;
      _notify();
    }
  }

  SceneTrialLimits? serverLimits;
  String? get _knownStopReason {
    final limits = serverLimits;
    if (limits == null) return null;
    if (limits.count >= limits.maxRequests) return 'trial-count';
    if (limits.expiresAtMs > 0 &&
        _clock().millisecondsSinceEpoch >= limits.expiresAtMs) {
      return 'window-expired';
    }
    if (limits.spentMicroUsd + 2458 > limits.budgetMicroUsd) {
      return 'budget-reserve';
    }
    if (limits.windowRemaining == 0) return 'allowance-stopped';
    return null;
  }

  bool get _knownExhausted => _knownStopReason != null;

  int noticeSequence = 0;
  String? notice, _noticeKey;
  void _setNotice(String key, String message) {
    if (!automatic || _noticeKey == key || restricted && key != 'restricted') {
      return;
    }
    _noticeKey = key;
    notice = message;
    noticeSequence++;
    _record('狀態提示：$key');
  }

  void _clearNotice() {
    notice = null;
    _noticeKey = null;
    noticeSequence++;
  }

  int _job = 0, _unsentFailures = 0, _rejectedReplies = 0;
  DateTime? _lastLocalAttempt;
  List<SceneObservation> _previousObservations = const [];
  LiveSceneSignal? _deliveredEvidence;
  String? spokenRequestId;
  SceneModeState get modeState => restricted
      ? SceneModeState.restricted
      : busy
      ? SceneModeState.analysing
      : speaking
      ? SceneModeState.speaking
      : automatic
      ? (!stable || failure.isNotEmpty
            ? SceneModeState.waiting
            : SceneModeState.observing)
      : SceneModeState.off;
  bool _newDirection = false;
  void _withdrawDescription(String reason) {
    _speechExpiry?.cancel();
    if (text != null || speaking) {
      unawaited(speaker.stop().catchError((Object _) {}));
    }
    text = null;
    speaking = false;
    speechStatus = '舊描述已撤回：$reason';
    _record(speechStatus);
  }

  void _clearContext() {
    _clearNotice();
    _previousFullText = null;
    _previousObservations = const [];
    _deliveredEvidence = null;
    _newDirection = false;
  }

  bool canDeliverText(String value) =>
      canDeliverSpeech && (_speechProbe || text == value);

  String phase = '未開始', backendStatus = '未送出', lastInvalidation = '無';
  String invalidationDetails = '無';
  String? rejectionReason, lastRequestId;
  int? captureMs, backendMs;
  final List<String> _trace = [];
  String speechStatus = '未交予播音';
  bool _speechSubmitted = false;
  bool get speechOutputSubmitted => _speechSubmitted;
  bool _speechProbe = false;
  bool get canTestSpeech => available && !busy && !speaking && !_disposed;
  bool get canDeliverSpeech =>
      !_disposed &&
      available &&
      speaking &&
      (_speechProbe || (text != null && _fresh));
  void speechEvent(SceneSpeechEvent event) {
    if (_disposed) return;
    _speechSubmitted = event == SceneSpeechEvent.submitted;
    speechStatus = switch (event) {
      SceneSpeechEvent.waiting => '等候物件提示完成（最多三秒）',
      SceneSpeechEvent.submitted => '已交予輸出路由，未確認發聲',
      SceneSpeechEvent.finished => '輸出路由已結束（不代表已聽到）',
      SceneSpeechEvent.cancelled => '未播：已取消或畫面不再有效',
      SceneSpeechEvent.interrupted => '已被較高優先語音／停止操作中斷',
      SceneSpeechEvent.priorityTimeout => '未播：等候物件提示逾時',
      SceneSpeechEvent.navigationBlocked => '未播：導航語音優先',
      SceneSpeechEvent.failed => '輸出路由失敗',
    };
    _record('播音：$speechStatus');
    _notify();
  }

  void playbackEvent(String code) {
    if (_disposed) return;
    const names = {
      'started': '原生 TTS 已開始',
      'completed': '原生 TTS 已完成',
      'cancelled': '原生 TTS 已取消',
      'failed': '原生 TTS 錯誤',
      'voiceover': '已提交 VoiceOver 公告（無發聲確認）',
    };
    final name = names[code];
    if (name == null) return;
    _record(name);
    _notify();
  }

  Future<void> testSpeech() async {
    if (!canTestSpeech) return;
    _archive();
    automatic = false;
    _clearContext();
    ++_generation;
    _expiry?.cancel();
    _evidence = null;
    text = null;
    _speechProbe = speaking = true;
    speechStatus = '本機測試準備中';
    _record('開始本機語音測試；不取相、不上傳、不呼叫後端');
    _notify();
    try {
      await speaker.stop();
      if (!canDeliverSpeech) return;
      await speaker
          .speak('呢段係本機廣東話語音測試，唔係環境描述。')
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () async {
              await speaker.stop();
              speechStatus = '本機語音測試逾時，已停止';
              _record(speechStatus);
            },
          );
    } catch (_) {
      speechStatus = '本機語音測試失敗';
      _record(speechStatus);
    } finally {
      _speechProbe = speaking = false;
      _notify();
    }
  }

  String get rejectionDescription => switch (rejectionReason) {
    'sentence-count' => '句數／句末格式不符（sentence-count）',
    'answer-format' => '回覆格式不符（answer-format）',
    'answer-length' => '描述過長（answer-length）',
    'disallowed-content' => '內容含受限字句（disallowed-content）',
    'provider-response' => '供應商回包格式不符（provider-response）',
    'provider-refusal' => '供應商拒答（provider-refusal）',
    'incomplete-answer' => '回覆未完整結束（incomplete-answer）',
    _ => '無／未提供',
  };
  void _record(String event) {
    _trace.add('${_clock().toIso8601String()} $event');
    if (_trace.length > 12) _trace.removeAt(0);
  }

  int get cooldownSeconds {
    final times = [?_lastAttempt, ?_lastLocalAttempt];
    if (times.isEmpty) return 0;
    final latest = times.reduce((a, b) => a.isAfter(b) ? a : b);
    final ms = (cooldown - _clock().difference(latest)).inMilliseconds;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }

  String get diagnostics =>
      backend is FirebaseSceneBackend &&
          (backend as FirebaseSceneBackend).diagnosticScope != _historyScope
      ? '帳戶已變更，不顯示上一帳戶測試資料。'
      : [
          _currentDiagnostics,
          if (_reports.isNotEmpty) '先前請求（最多三次；只含數值及狀態）：',
          ..._reports.values,
        ].join('\n\n');
  String get _currentDiagnostics => [
    '模式：${automatic ? '自動開啟' : '自動關閉'}；相機來源：${available ? '可用' : '未準備'}',
    '階段：$phase；模式狀態：${modeState.name}；後端結果：$backendStatus',
    '播音所屬請求：${spokenRequestId ?? '無'}；脈絡觀察項目：${_previousObservations.length}',
    '有效描述字數：${text?.length ?? 0}；播音：$speechStatus',
    if (speechEnvironment != null) '語音設定：${speechEnvironment!()}',
    '請求 ID：${lastRequestId ?? '未送出'}',
    '停止原因：${stopReason ?? _knownStopReason ?? '無'}；格式細項：${rejectionDetail ?? '無'}；狀態讀取：${_checkingStatus ? '進行中' : '完成／未開始'}',
    '作廢原因：$lastInvalidation；拒絕原因：$rejectionDescription；錯誤碼：${failure.isEmpty ? '無' : failure}',
    '作廢時數值：$invalidationDetails',
    '穩定：${stable ? '是' : '否'}（需 ${stableFor.inMilliseconds} ms）；畫面年齡：${_received == null ? '未知' : '${_clock().difference(_received!).inMilliseconds} ms'}',
    '角速度：${_latest?.rotationRate.toStringAsFixed(3) ?? '未知'} rad/s（取相上限 0.8）',
    '與上次請求相比：畫面差 ${_baseline == null || _latest == null ? '未知' : _baseline!.difference(_latest!).toStringAsFixed(3)}／轉向 ${_baseline == null || _latest == null ? '未知' : _baseline!.angle(_latest!).toStringAsFixed(1)} 度（候選門檻：結構差 0.12／18 度，並非語意變化）',
    '冷卻剩餘：$cooldownSeconds 秒；本次已嘗試：$attempts／$maxSessionAttempts',
    '伺服器最近核對：${serverLimits == null ? '未知' : '累計 ${serverLimits!.count}／${serverLimits!.maxRequests} 次；許可餘下 ${serverLimits!.windowRemaining} 次；估算 ${serverLimits!.spentMicroUsd}／${serverLimits!.budgetMicroUsd} microUSD'}',
    '許可到期：${serverLimits == null || serverLimits!.expiresAtMs == 0 ? '未知' : DateTime.fromMillisecondsSinceEpoch(serverLimits!.expiresAtMs).toLocal().toIso8601String()}',
    '取相：${captureMs ?? '未知'} ms；後端往返：${backendMs ?? '未知'} ms；模型：${metrics?.modelMs ?? '未知'} ms',
    'Token 輸入／輸出／合計：${metrics?.promptTokens ?? '未知'}／${metrics?.completionTokens ?? '未知'}／${metrics?.totalTokens ?? '未知'}',
    '最近一次估算：US\$${metrics?.estimatedUsd?.toStringAsFixed(6) ?? '未知'}；本次已知累計：US\$${estimatedUsd.toStringAsFixed(6)}${usageUnknown ? '（另有未知用量）' : ''}；不是帳單硬上限',
    '最近事件（只保留本機數值及狀態，不含照片或描述）：',
    ..._trace,
    if (_remoteReports.isNotEmpty) '伺服器最近結果（最多三次；只有數值及狀態，重入可讀）：',
    ..._remoteReports,
  ].join('\n');
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool get _fresh =>
      _received != null &&
      _clock().difference(_received!) <= const Duration(seconds: 1);
  bool get stable =>
      _fresh &&
      _stableSince != null &&
      _clock().difference(_stableSince!) >= stableFor;
  bool get canRequest =>
      available &&
      !busy &&
      !_checkingStatus &&
      !restricted &&
      !_knownExhausted &&
      !_speechProbe &&
      attempts < maxSessionAttempts &&
      (_lastAttempt == null ||
          _clock().difference(_lastAttempt!) >= cooldown) &&
      (_lastLocalAttempt == null ||
          _clock().difference(_lastLocalAttempt!) >= cooldown);
  bool get canDescribe => canRequest && stable;
  bool get _changed =>
      (_previousFullText == null && failure != 'rejected') ||
      _baseline == null ||
      (_latest != null &&
          (_baseline!.structuralDifference(_latest!) >= 0.12 ||
              _baseline!.angle(_latest!) >= 18));

  void setAvailable(bool value, {bool preserveMode = false}) {
    if (_disposed) return;
    available = value;
    if (value) preparationCode = null;
    if (!value) {
      if (!preserveMode) automatic = false;
      _latest = _stable = _baseline = null;
      if (!preserveMode) _clearContext();
      _stableSince = _received = null;
      _freshness?.cancel();
      invalidate(reason: '辨識暫停／來源停止');
      status = restricted
          ? sceneStopMessage(stopReason ?? _knownStopReason, serverLimits)
          : '場景分析已暫停；繼續辨識後可手動啟動。';
    } else {
      status = restricted
          ? sceneStopMessage(stopReason ?? _knownStopReason, serverLimits)
          : '保持手機穩定，準備場景分析。';
    }
    _notify();
  }

  void preparationFailed(String code) {
    setAvailable(false, preserveMode: true);
    _setNotice('source-wait', '場景暫時未能更新，等候相機重新接通。');
    preparationCode = code;
    if (!restricted) {
      status = switch (code) {
        'not_running' || 'not_ready' => '場景取相尚未接上辨識相機，請按「重試場景準備」。',
        'missing_plugin' => '場景相機介面尚未接通，請按「重試場景準備」。',
        'timeout' => '場景準備逾時，請按「重試場景準備」。',
        _ => '場景準備未完成，請按「重試場景準備」。',
      };
    }
    _notify();
  }

  void setAutomatic(bool value) {
    if (_disposed) return;
    automatic =
        value &&
        available &&
        attempts < maxSessionAttempts &&
        !usageUnknown &&
        !restricted;
    if (!automatic) {
      _clearContext();
      invalidate(reason: '自動模式關閉');
    }
    if (automatic) {
      _baseline = null;
      _clearContext();
    }
    status = restricted
        ? sceneStopMessage(stopReason ?? _knownStopReason, serverLimits)
        : automatic
        ? '已開啟自動場景分析，環境有重要變化且穩定後才取相。'
        : '自動場景分析已關閉。';
    _notify();
  }

  /// Explicit interruption: no automatic restart after overlays/background.
  void interrupt() {
    automatic = false;
    _clearContext();
    invalidate(reason: '使用者停止／操作中斷');
    _notify();
  }

  void invalidate({String reason = '已取消', String details = '無'}) {
    ++_generation;
    _expiry?.cancel();
    _speechExpiry?.cancel();
    lastInvalidation = reason;
    invalidationDetails = details;
    phase = restricted ? '受限待處理' : '已作廢／已取消';
    _speechProbe = false;
    _speechSubmitted = false;
    _record('作廢：$reason${details == '無' ? '' : '；$details'}');
    if (text != null || busy || speaking) {
      unawaited(speaker.stop().catchError((Object _) {}));
    }
    text = null;
    _evidence = null;
    status = restricted
        ? sceneStopMessage(stopReason ?? _knownStopReason, serverLimits)
        : automatic
        ? '舊描述已作廢；自動模式仍開啟，等新畫面穩定及冷卻完成後再分析。'
        : '舊描述已作廢；自動模式關閉，不會自行再分析。';
    _notify();
  }

  void observe(LiveSceneSignal? signal, {String? sourceIssue}) {
    if (_disposed || !available) return;
    if (signal == null ||
        (_latest != null && signal.sequence <= _latest!.sequence)) {
      _stable = null;
      _stableSince = null;
      if (_speechProbe) {
        _notify();
        return;
      }
      if (failure.isNotEmpty && !busy && text == null) {
        _notify();
        return;
      }
      invalidate(reason: sourceIssue ?? '畫面／轉向訊號無效');
      _setNotice('source-wait', '場景暫時未能更新，等候有效畫面。');
      if (!restricted) {
        status = switch (sourceIssue) {
          'waiting-motion' => '正在等候手機轉向感測資料，未有取相或雲端請求。',
          'motion-stale' => '手機轉向資料已過期，等候新資料後再分析。',
          'motion-unavailable' => '手機暫未提供轉向感測，未有取相或雲端請求。',
          _ => '未取得可靠的新畫面或轉向資訊，場景分析暫停。',
        };
      }
      _notify();
      return;
    }
    final now = _clock();
    _latest = signal;
    _received = now;
    _freshness?.cancel();
    _freshness = Timer(const Duration(seconds: 1), () {
      if (_disposed) return;
      _stable = null;
      _stableSince = null;
      if (_speechProbe) {
        _notify();
        return;
      }
      if (failure.isNotEmpty && !busy && text == null) {
        _notify();
        return;
      }
      invalidate(reason: '畫面超過一秒未更新');
      if (!restricted) status = '畫面已過期，場景描述已作廢。';
      _setNotice('source-wait', '場景暫時未能更新，等候有效畫面。');
      _notify();
    });
    // Hand tremor does not invalidate content. Fast panning or accumulated
    // scene/attitude change still fences old replies immediately.
    final moving = signal.rotationRate > 0.8;
    final fastTurn = signal.rotationRate > 1.8;
    final drift =
        _stable != null &&
        (_stable!.structuralDifference(signal) > 0.12 ||
            _stable!.angle(signal) > 12);
    final evidenceChanged =
        _evidence != null &&
        (_evidence!.angle(signal) >= 29.5 ||
            _evidence!.structuralDifference(signal) > 0.4);
    if (evidenceChanged ||
        (fastTurn && _evidence != null && _evidence!.angle(signal) > 12)) {
      _newDirection = true;
      invalidate(
        reason: fastTurn ? '快速轉向' : '相對取相畫面／姿態明顯改變',
        details:
            '角速度 ${signal.rotationRate.toStringAsFixed(3)} rad/s；相對取相畫面差 ${_evidence!.difference(signal).toStringAsFixed(3)}／轉向 ${_evidence!.angle(signal).toStringAsFixed(1)} 度（作廢門檻：30 度／結構差 0.4；快轉須累積轉角）',
      );
    }
    if (_deliveredEvidence != null &&
        text != null &&
        _deliveredEvidence!.angle(signal) >= 29.5) {
      _newDirection = true;
      _withdrawDescription('方向已改變');
    }
    if (moving || drift || _stable == null || _stableSince == null) {
      _stable = signal;
      _stableSince = now;
    }
    if (moving) {
      _stableSince = null;
      if (!restricted && !busy && text == null && failure.isEmpty) {
        status = automatic
            ? '等畫面稍為穩定後再分析；自動模式仍然開啟。'
            : '畫面移動中；場景模式關閉。開啟模式後會等穩定再取相。';
      }
    }
    if (automatic && _knownExhausted && !busy && !speaking) {
      restricted = true;
      phase = '受限待處理';
      stopReason = _knownStopReason;
      status = sceneStopMessage(stopReason, serverLimits);
      _setNotice('restricted', '場景試驗已到限制，暫停新分析。');
    }
    if (automatic && canDescribe && _changed) {
      unawaited(describe(manual: false));
    }
    _notify();
  }

  Future<void> describe({bool manual = true}) async {
    if (!(manual ? canRequest : canDescribe) || (!manual && !automatic)) return;
    _archive();
    final job = ++_job;
    final mode = _previousFullText == null ? 'overview' : 'update';
    _lastLocalAttempt = _clock();
    busy = true;
    failure = '';
    rejectionReason = rejectionDetail = stopReason = null;
    lastRequestId = null;
    metrics = null;
    captureMs = backendMs = null;
    backendStatus = '未送出';
    speechStatus = '未交予播音';
    lastInvalidation = '無';
    invalidationDetails = '無';
    phase = '等候穩定';
    _trace.clear();
    _record(
      manual
          ? '手動單次開始'
          : _baseline == null
          ? '自動首次描述'
          : '環境重要變化觸發',
    );
    final generation = ++_generation;
    _evidence = null;
    bool active() => !_disposed && available && generation == _generation;
    bool current() => active() && _fresh;
    status = '等畫面稍為穩定後取相；即時物件辨識繼續運行。';
    _notify();
    var awaitingResult = false;
    DateTime? backendStarted;
    try {
      // A manual request can wait locally; no camera photo or paid work is
      // queued. Pause/exit cancels this wait before any upload.
      for (var i = 0; manual && active() && !stable && i < 25; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!active()) return;
      if (!stable) throw const SceneFailure('not-stable', beforeProvider: true);
      _evidence = _latest;
      phase = '取相中';
      _record('開始本機取相');
      status = '正在分析場景；即時物件辨識繼續運行。';
      _notify();
      final captureStarted = _clock();
      final jpeg = await capture();
      captureMs = _clock().difference(captureStarted).inMilliseconds;
      if (!current()) {
        _record('取相後已作廢，未交後端');
        return;
      }
      if (jpeg == null || jpeg.isEmpty || jpeg.length > 524288) {
        throw const SceneFailure('no-frame', beforeProvider: true);
      }
      if ((_latest?.rotationRate ?? double.infinity) > 0.8) {
        invalidate(reason: '編碼後手機仍在移動，未送出');
        return;
      }
      // Debit locally only immediately before the one backend attempt.
      attempts++;
      _lastAttempt = _clock();
      _baseline = _latest;
      phase = '等待後端';
      backendStatus = '等待回覆';
      lastRequestId = sceneRequestId();
      backendStarted = _clock();
      _record('已交後端連接器進行驗證／送出，尚待回覆確認');
      _expiry = Timer(const Duration(seconds: 12), () {
        if (!_disposed && generation == _generation) {
          final pending = busy;
          invalidate(reason: pending ? '分析超過十二秒' : '描述有效期結束');
          // Keep mode intent; no second request while the first is in flight.
          status = pending ? '場景分析逾時，沒有自動重試。' : '場景描述已過期。';
          _notify();
        }
      });
      awaitingResult = true;
      final id = lastRequestId!;
      final reply = backend is SceneModeBackend
          ? await (backend as SceneModeBackend).describeMode(
              jpeg,
              id,
              mode: mode,
              isCurrent: current,
            )
          : await backend.describe(jpeg, id, isCurrent: current);
      awaitingResult = false;
      _expiry?.cancel();
      if (!_disposed) {
        backendMs = _clock().difference(backendStarted).inMilliseconds;
        backendStatus = reply.text == null ? '拒絕' : '成功';
        rejectionReason = reply.rejectionReason;
        rejectionDetail = reply.rejectionDetail;
        _record(
          '後端：$backendStatus${rejectionReason == null ? '' : '／$rejectionReason'}${rejectionDetail == null ? '' : '／$rejectionDetail'}',
        );
        metrics = reply.metrics;
        serverLimits = reply.limits ?? serverLimits;
        if (reply.metrics.estimatedUsd == null ||
            reply.metrics.totalTokens == null) {
          usageUnknown = true;
          restricted = true;
          _setNotice('restricted', '場景分析暫停，用量需要核對。');
        } else {
          estimatedUsd += reply.metrics.estimatedUsd!;
        }
      }
      if (reply.text == null) {
        failure = 'rejected';
        _rejectedReplies++;
        if (_rejectedReplies >= 2) restricted = true;
        _setNotice(
          restricted ? 'restricted' : 'answer-wait',
          restricted ? '場景分析暫停，回覆需要核對。' : '暫時未能提供新描述，等候新畫面。',
        );
        if (current()) {
          phase = restricted ? '受限待處理' : '回覆被拒絕';
          status = restricted ? '連續回覆未符合要求，暫停新分析。' : '回覆未符合要求；等候新環境，不重傳同一畫面。';
          _expiry?.cancel();
          _evidence = null;
        }
        return;
      }
      if (!current()) {
        speechStatus = '未交予播音：回覆到達時畫面已作廢';
        _record(speechStatus);
        return;
      }
      if (!restricted) _clearNotice();
      _rejectedReplies = _unsentFailures = 0;
      final full = validateSceneText(
        reply.text,
        minSentences: reply.mode == 'update' ? 1 : 2,
        maxSentences: reply.mode == 'update' ? 1 : 3,
      );
      final facts = reply.observations.map((o) => o.semanticKey).toSet();
      final previousFacts = _previousObservations
          .map((o) => o.semanticKey)
          .toSet();
      final newDirection =
          _newDirection ||
          _deliveredEvidence != null &&
              _latest != null &&
              _deliveredEvidence!.angle(_latest!) >= 29.5;
      final duplicate = reply.mode == null
          ? _previousFullText == full
          : facts.difference(previousFacts).isEmpty &&
                previousFacts.difference(facts).isEmpty &&
                !newDirection;
      if (!manual && mode == 'update' && duplicate) {
        phase = '持續觀察';
        status = '未有值得補充的新重點，略過重複播音。';
        _record('本機重點比較：沒有新資訊');
        return;
      }
      final previousFullText = _previousFullText;
      _newDirection = false;
      _previousFullText = full;
      _previousObservations = reply.observations;
      _deliveredEvidence = _latest;
      final spoken = reply.mode == null && !manual && previousFullText != null
          ? RegExp(r'[^。！？]+[。！？]')
                .allMatches(full)
                .map((m) => m[0]!)
                .where((sentence) => !previousFullText.contains(sentence))
                .join()
          : full;
      if (spoken.isEmpty) {
        status = '沒有新句子，略過重複播音。';
        return;
      }
      spokenRequestId = id;
      text = spoken;
      phase = '有效文字已備妥／交予播音';
      speechStatus = '等候語音協調器';
      _record('有效文字已備妥，交予語音協調器');
      status = '場景描述完成。';
      busy = false;
      speaking = true;
      _speechExpiry?.cancel();
      _speechExpiry = Timer(const Duration(seconds: 15), () {
        if (!_disposed && spokenRequestId == id && text == spoken) {
          _withdrawDescription('描述有效期結束');
        }
      });
      _notify();
      try {
        await speaker.speak(spoken);
      } catch (_) {
        if (current() && spokenRequestId == id) {
          failure = 'speech-unavailable';
          speechStatus = '未能啟動廣東話播音';
          _record('廣東話播音未能開始');
          status = '廣東話播音未能開始，可閱讀場景文字。';
        }
      } finally {
        if (spokenRequestId == id) speaking = false;
      }
    } catch (error) {
      final safe = error is SceneFailure && error.beforeProvider;
      if (!_disposed) {
        if (awaitingResult) {
          backendStatus = '失敗';
          backendMs = _clock().difference(backendStarted!).inMilliseconds;
        }
        failure = error is SceneFailure ? error.code : 'unavailable';
        if (error is SceneFailure) {
          stopReason = error.stopReason;
          serverLimits = error.limits ?? serverLimits;
        }
        _record('失敗：$failure');
      }
      if (!_disposed && awaitingResult && !safe) {
        usageUnknown = restricted = true;
      }
      if (safe && failure != 'not-stable') {
        _unsentFailures++;
        if (_unsentFailures > 2 ||
            const {
              'resource-exhausted',
              'not-configured',
              'unauthenticated',
              'permission-denied',
              'app-check-unavailable',
            }.contains(failure)) {
          restricted = true;
        } else {
          _baseline = null;
        }
      }
      if (!active()) return;
      _setNotice(
        restricted ? 'restricted' : 'update-wait',
        restricted ? '場景分析暫停，額度或結果需要核對。' : '場景暫時未能更新，稍後自動恢復。',
      );
      phase = restricted ? '受限待處理' : '等候更新';
      _expiry?.cancel();
      _evidence = null;
      text = null;
      status = switch (failure) {
        'not-stable' => '畫面仍在移動，今次未取相或上傳；稍為穩定後可再按。',
        'resource-exhausted' => sceneStopMessage(stopReason, serverLimits),
        'app-check-unavailable' ||
        'unauthenticated' ||
        'not-configured' => '場景分析登入或手機驗證未完成；物件辨識繼續。',
        'speech-unavailable' => '廣東話播音未能開始，可閱讀場景文字。',
        _ => restricted ? '場景模式受限，結果或費用需核對，暫停新分析。' : '暫時未能更新；在確認未送出及次數限制內恢復。',
      };
    } finally {
      if (job == _job) busy = false;
      if (!_disposed && attempts >= maxSessionAttempts) {
        restricted = true;
        _setNotice('restricted', '場景分析已達測試次數上限，暫停新分析。');
        status += ' 本次使用的分析次數已達上限。';
      }
      _notify();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _archive();
    invalidate();
    _disposed = true;
    _freshness?.cancel();
    _expiry?.cancel();
    _speechExpiry?.cancel();
    super.dispose();
  }
}
