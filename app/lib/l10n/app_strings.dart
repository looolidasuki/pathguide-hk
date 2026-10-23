import 'app_locale.dart';
import '../vision/labels.dart';

/// All user-visible UI copy.
///
/// Two packs only: English (default / fallback) and Hong Kong Traditional
/// Chinese. System locales `zh*` / `yue` map to the Chinese pack; everything
/// else uses English. `supportedLocales` may list more variants so Material
/// widgets localize — that is not a third UI pack.
class AppStrings {
  const AppStrings._(this.language);

  final AppLanguage language;

  static AppStrings of(AppLanguage language) => AppStrings._(language);

  static AppStrings get current => AppStrings._(AppLocale.current);

  bool get _zh => language == AppLanguage.zh;

  String get appTitle => _zh ? '領路通' : 'PathGuide';

  String get initializing => _zh ? '正在初始化…' : 'Initializing…';

  String initializingSource(String name) =>
      _zh ? '正在初始化（$name）…' : 'Initializing ($name)…';

  String inferenceStreamError(Object e) =>
      _zh ? '推理流出錯：$e' : 'Inference stream error: $e';

  String get mockSelectCamera => _zh
      ? '模擬畫面：選擇「相機」以開始即時識別'
      : 'Mock view: select Camera to start live detection';

  String ttsFallbackWarning(String lang) => _zh
      ? '警告：未找到符合系統語言的語音包，目前使用 $lang'
      : 'Warning: no matching system voice found, using $lang';

  String get ttsNotReady => _zh ? '未就緒' : 'Not ready';

  String get fps => 'FPS';

  String get inference => _zh ? '推理' : 'Infer';

  String get boxes => _zh ? '檢測框' : 'Boxes';

  String get analyzedFrames => _zh ? '分析幀' : 'Analyzed';

  String get analyzeErrors => _zh ? '分析錯誤' : 'Analyze errors';

  String get scoreRange => _zh ? '分數' : 'Score';

  String get voice => _zh ? '語音' : 'Voice';

  String speakFloor(String value) => _zh
      ? '播報門檻 ≥ $value（低分只畫框）'
      : 'Speak floor ≥ $value (low scores draw only)';

  String get frame => _zh ? '幀' : 'Frame';

  String get rotation => _zh ? '旋轉' : 'Rotation';

  String get scale => 'scale';

  String get letterbox => _zh ? '留邊' : 'Pad';

  String get uncategorized => _zh ? '（未分類）' : '(uncategorized)';

  String get errorCopied => _zh ? '錯誤詳情已複製' : 'Error details copied';

  String sourceInitFailed(String name) => _zh
      ? '$name 初始化失敗（長按複製）'
      : '$name failed to start (long-press to copy)';

  String get sourceFallback => _zh ? '來源' : 'Source';

  String get displayThreshold => _zh ? '顯示閾值' : 'Display threshold';

  String get camera => _zh ? '相機' : 'Camera';

  String get mock => _zh ? '模擬' : 'Mock';

  String get iosDemo => _zh ? 'iOS 演示' : 'iOS demo';

  String get fakeData => _zh ? '假數據' : 'Fake data';

  String get muteSpeak => _zh ? '關閉播報' : 'Mute speech';

  String get unmuteSpeak => _zh ? '開啟播報' : 'Enable speech';

  String get speakEnabledProbe =>
      _zh ? '語音播報已開啟' : 'Voice announcements enabled';

  String get hideLabels => _zh ? '隱藏標籤' : 'Hide labels';

  String get showLabels => _zh ? '顯示標籤' : 'Show labels';

  String get invalidDetections => _zh ? '無效' : 'Invalid';

  String get input => _zh ? '輸入' : 'Input';

  String get output => _zh ? '輸出' : 'Output';

  String geometryMismatch(int rawW, int rawH, int frameW, int frameH) => _zh
      ? '幾何不一致：畫框用 ${rawW}x$rawH，分析流實際 ${frameW}x$frameH → 框會整體偏移'
      : 'Geometry mismatch: overlay ${rawW}x$rawH vs analyze ${frameW}x$frameH';

  // --- Announcer decision reasons (UI log) ---

  String get reasonSkipPrefix => _zh ? '跳過：' : 'skip: ';

  String get reasonNormal => _zh ? '正常播報' : 'speak';

  String get reasonForced => _zh ? '強制播報' : 'forced speak';

  String scoreBelowFloor(String score, String floor) => _zh
      ? '分數 $score 低於播報門檻 $floor'
      : 'score $score below speak floor $floor';

  String get perClassCooldown => _zh ? '同類冷卻未過' : 'per-class cooldown';

  String get globalCooldown => _zh ? '全局冷卻未過' : 'global cooldown';

  bool reasonIsSkip(String reason) =>
      reason.startsWith(reasonSkipPrefix) ||
      reason.startsWith('跳過：') ||
      reason.startsWith('跳过：') ||
      reason.startsWith('skip: ');

  // --- Vision source names / status (must follow system language) ---

  String get sourceCamera => _zh ? '相機' : 'Camera';

  String get sourceMock => _zh ? '假數據' : 'Fake data';

  String get sourceWebCamera => _zh ? '瀏覽器相機' : 'Browser camera';

  String get mockModeReady => _zh
      ? '假數據模式：三個按已知規律運動的框，用於校驗座標映射'
      : 'Fake-data mode: three moving boxes for overlay checks';

  String get cameraNotStarted => _zh ? '相機未啟動' : 'Camera not started';

  String get cameraNotStartedDetail => _zh
      ? '模型已載入，但原生相機未啟動：可能未授予權限，或被其他程式佔用'
      : 'Model loaded, but the native camera did not start (permission or in use)';

  String get modelManifestBad => _zh ? '模型清單有問題' : 'Model manifest invalid';

  String get modelManifestMismatch => _zh ? '模型與清單不符' : 'Model/manifest mismatch';

  String modelManifestMismatchDetail({
    required int modelClassCount,
    required String version,
    required int declaredCount,
    required Object declaredIds,
  }) =>
      _zh
          ? '模型報告 $modelClassCount 類，而清單（$version）聲明 '
              'modelClassCount=$declaredCount、modelClassIds=$declaredIds。'
              '兩者必須一致——猜一個映射會把框標成別的類，而且不會報錯。'
          : 'Model reports $modelClassCount classes, but manifest ($version) declares '
              'modelClassCount=$declaredCount, modelClassIds=$declaredIds. '
              'They must match — guessing a mapping mislabels boxes silently.';

  String get modelNotLoaded => _zh ? '模型未載入' : 'Model not loaded';

  String modelLoaded({
    required int classCount,
    required Object inputSize,
    String mappingNote = '',
  }) =>
      _zh
          ? '模型已載入（類別數 $classCount，輸入 $inputSize）$mappingNote'
          : 'Model loaded ($classCount classes, input $inputSize)$mappingNote';

  String get webCameraNotStarted =>
      _zh ? '瀏覽器相機未啟動' : 'Browser camera not started';

  String get webCameraReady =>
      _zh ? '即時相機識別已啟動（TFLite）' : 'Live camera detection started (TFLite)';

  String get webCameraWebOnly =>
      _zh ? '瀏覽器相機僅支援 Web' : 'Browser camera is only available on Web';

  String get webCameraPreviewNotReady =>
      _zh ? '相機預覽尚未準備好，請重試' : 'Camera preview is not ready; try again';

  String get webCameraNeedsHttps => _zh
      ? '瀏覽器相機需要 HTTPS；請透過安全連線開啟此頁面'
      : 'Browser camera needs HTTPS; open this page over a secure connection';

  String webCameraStartFailed(Object error) =>
      _zh ? '啟動瀏覽器相機失敗：$error' : 'Failed to start browser camera: $error';

  // --- 產品畫面（單一畫面）---
  //
  // 這些是**使用者會聽到**的句子，所以每一條都要能只靠聽就懂。
  // 命名原則：標籤即結果，不用「開始」「確定」這類模糊詞
  //（見 docs/A11Y-ENTRY-AND-AUTH.md 的驗收清單）。

  /// 主按鈕：相機尚未就緒時。
  String get startGuidance => _zh ? '啟動引導' : 'Start guidance';

  /// 按下「啟動引導」之後的即時回饋。**先出聲再做事**——
  /// 這個專案把「按了之後沒反應」列為最嚴重的缺口。
  String get starting => _zh ? '正在啟動引導' : 'Starting guidance';

  /// 引導中，狀態列文字（也會被唸出來）。
  String get guiding => _zh ? '正在引導，前方有障礙物會出聲' : 'Guiding — obstacles will be announced';

  /// 引導已停止（回到未啟動狀態）。
  String get guidanceStopped => _zh ? '已停止引導' : 'Guidance stopped';

  /// 語音開關的標籤：label 是**動作 + 結果**，不是狀態。
  /// 螢幕閱讀器唸的是「要按下去會發生什麼」，不是「現在是什麼」。
  String get enableVoice => _zh ? '開啟語音' : 'Turn voice on';

  String get disableVoice => _zh ? '關閉語音' : 'Turn voice off';

  /// 停止引導。label 同樣是動作 + 結果。
  String get stopGuidance => _zh ? '結束引導' : 'End guidance';

  // --- 採集 ---
  //
  // 產品畫面上已無採集入口（見 `docs/UPSTREAM-MERGE-ASSESSMENT.md` §6.2），
  // 所以這裡的採集字串一併移除：留著只會被下一個人當成「還有這個功能」。

  /// 點下語音開關後的確認（讓使用者知道按到了）。
  String get voiceOn => _zh ? '語音已開啟' : 'Voice on';

  String get voiceOff => _zh ? '語音已關閉' : 'Voice off';

  /// 讀到招牌時唸出的前置詞。**必須加**，否則使用者分不清
  /// 「前面有樓梯」（障礙物）與「麥當勞」（招牌）——兩者都是名詞。
  String get readSignPrefix => _zh ? '招牌寫著' : 'Sign reads';

  /// 出現率很低的事實陳述，用完整句避免被聽成指令。
  String get noCameraOnDevice => _zh
      ? '這台裝置沒有可用的相機，引導無法啟動'
      : 'No camera available on this device, so guidance cannot start';

  // --- 主界面：兩個模式 ---
  //
  // 兩個模式是**互斥**的，因為它們會互搶 CPU 與語音（真機實測：
  // 招牌有一半被障礙物播報讓位丟掉）。所以讓使用者明確選一個。

  /// 標題。主界面是唯一需要「這個 App 叫什麼」的地方。
  String get homeTitle => _zh ? '領路通' : 'PathGuide';

  /// 模式一：障礙物引導。
  String get modeGuidance => _zh ? '開始引導' : 'Start guidance';

  /// 一句話說明這個模式在做什麼（給低視力使用者與陪護者）。
  String get modeGuidanceHint =>
      _zh ? '偵測前方障礙物並出聲提醒' : 'Detect obstacles ahead and announce them';

  /// 模式二：讀字（招牌、菜單、指示牌……）。
  String get modeReadText => _zh ? '讀字' : 'Read text';

  String get modeReadTextHint => _zh
      ? '讀招牌、菜單、指示牌上的文字'
      : 'Read text on signs, menus and notices';

  // --- 讀字畫面 ---

  /// 進入讀字模式時的第一句話。
  String get readTextReady => _zh
      ? '讀字模式。對著文字，讀到就會唸出來。'
      : 'Text mode. Point at text and it will be read out.';

  String get readAgain => _zh ? '再讀一次' : 'Read again';

  /// 讀字中（避免使用者以為按了沒反應）。
  String get reading => _zh ? '正在讀取…' : 'Reading…';

  /// ★ 讀不到字時**必須出聲**。
  ///
  /// 原本是靜默的，結果是使用者分不出「畫面裡沒字」與「功能壞了」——
  /// 全盲使用者沒有任何視覺線索可以判斷，只能反覆對準、反覆失望。
  String get noTextFound =>
      _zh ? '沒有看到文字，請靠近一點或對準一點' : 'No text found — move closer or aim again';

  /// 回到主界面。
  String get backToHome => _zh ? '返回' : 'Back';

  // --- 設定頁 ---
  //
  // 設定頁只有三類內容：播報速度、模型資訊、返回。**刻意沒有第三塊**
  // 「未來功能」清單——每一項都要花一次焦點移動去聽「這個還沒做」。

  String get settingsTitle => _zh ? '設定' : 'Settings';

  String get settingsHint => _zh ? '只調整語音速度；辨識門檻由程式決定' : 'Speech speed only';

  String get speechSpeed => _zh ? '播報速度' : 'Speech speed';

  String get speechSpeedSlow => _zh ? '慢' : 'Slow';

  String get speechSpeedNormal => _zh ? '正常' : 'Normal';

  String get speechSpeedFast => _zh ? '快' : 'Fast';

  String get modelInfo => _zh ? '模型資訊' : 'Model info';

  /// 模型大小的顯示文字，例如 `2.87 MB`。
  ///
  /// 單位也算文案：`' MB'` 這種字面量留在 widget 裡，就等於每張畫面各寫一次
  /// 同一句話，有一天要改單位就得追好幾處。
  String modelSize(double megabytes) => '${megabytes.toStringAsFixed(2)} MB';

  /// 清單沒寫檔案大小時，大小欄位要顯示什麼。
  String get modelSizeUnknown => '—';

  /// 模型資訊那一行的完整摘要，例如「18 類 · 2.87 MB · 2026-10-02.stage2」。
  ///
  /// 「類」與「classes」是文案不是佈局，所以要跟其他字串一起翻。
  String modelSummaryLine({
    required int classCount,
    required String sizeText,
    required String version,
  }) =>
      _zh
          ? '$classCount 類 · $sizeText · $version'
          : '$classCount classes · $sizeText · $version';

  /// 摘要還沒讀回來（或讀失敗）時要說什麼。
  ///
  /// **不能唸破折號**：螢幕閱讀器唸「—」是 “dash”，對使用者零資訊；
  /// 但「載入中」至少告訴他再等一下。
  String get modelInfoLoading => _zh ? '載入中' : 'Loading';

  /// 模型資訊整塊的**唯一**一句話：標題一次、摘要一次。
  ///
  /// 整塊只留一個語意節點（內層文字全走 `ExcludeSemantics`），所以這句話
  /// 就是使用者聽到的那一句，不會先聽到標題、再聽一次標題加摘要。
  String modelInfoSpoken(String summary) =>
      _zh ? '模型資訊：$summary' : 'Model info: $summary';

  /// 主速度列的一句話：動作 + 現況 + 下一步。
  ///
  /// 螢幕閱讀器唸的是「標籤 + 按鈕」，所以標籤要自己說清楚按下去會怎樣；
  /// 只唸「播報速度，正常」等於什麼都沒說。
  String speechSpeedAction(String current) => _zh
      ? '播報速度，現為$current，點兩下調整'
      : 'Speech speed, currently $current, double-tap to change';

  /// 「已選取」三個字。
  ///
  /// 顏色與勾選圖示對全盲使用者都不存在，選中狀態必須能用聽的。
  String get speechSpeedSelected => _zh ? '已選取' : 'selected';

  /// 語速選項列的標籤：動作 + 結果 + 狀態。
  String speechSpeedChoice(String name, {required bool selected}) {
    if (!selected) return _zh ? '選$name' : 'Choose $name';
    return _zh ? '$name，$speechSpeedSelected' : '$name, $speechSpeedSelected';
  }

  String get account => _zh ? '帳號' : 'Account';

  String get accountGuest => _zh ? '訪客（可完整使用識別）' : 'Guest (full detection)';

  /// 已登入狀態的帳號列文字（設定頁帳號列用）。
  String get accountSignedIn => _zh ? '已登入' : 'Signed in';

  /// 設定頁帳號列的**一句話**：動作 + 現況 + 下一步。
  ///
  /// 只唸「帳號，訪客」時，使用者不知道這是一顆按鈕、也不知道按下去會發生
  /// 什麼；而「已登入」若不加動作，他也不會知道這裡還進得去帳號頁。
  /// 現況字串由呼叫端給（訪客那句要順帶說明識別仍可完整使用）。
  String accountAction(String state) => _zh
      ? '帳號，現為$state，點兩下開啟帳號頁'
      : 'Account, currently $state, double-tap to open account page';

  // --- 雲能力門禁的**可操作**說明 ---
  //
  // 門禁訊息不是「無權限」，而是「怎麼才能用」：使用者聽到「無權限」只知道
  // 路走不通，聽到「需要登入」才知道下一步要做什麼（spec §1.1）。
  // 兩句都要順帶說明核心識別不受影響，否則使用者會以為 App 壞了。

  /// 訪客碰到雲能力時的一句話（要說出解鎖方式）。
  String get deniedNeedsLogin => _zh
      ? '這功能需要登入；未登入時識別仍可完整使用'
      : 'Sign in for this feature. Detection works without it';

  /// 已登入但離線時的一句話（要說出缺的是網絡）。
  String get deniedNeedsNetwork =>
      _zh ? '暫時沒有網絡；識別不受影響' : 'No network right now. Detection is unaffected';
}

/// Localized display / speak name for a detection label.
String labelDisplayName(Label label, [AppLanguage? language]) {
  final lang = language ?? AppLocale.current;
  return lang == AppLanguage.zh ? label.nameZh : label.nameEn.replaceAll('_', ' ');
}
