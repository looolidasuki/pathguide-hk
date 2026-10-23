import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../vision/model_manifest.dart';
import '../vision/platform_vision.dart' show defaultModelManifestKey;
import 'api_types.dart';
import 'feature_gate.dart';
import 'path_guide_api.dart';

/// 待上傳素材的來源。真實實現讀應用私有目錄；測試用記憶體。
///
/// `pendingPaths()` **必須按時間升序**回傳（最舊的在前面）：`trim()` 依這個
/// 假設丟掉「最舊的」，順序反過來就會丟掉剛剛錄的素材。
///
/// ★ **`remove` 可以拋，隊列必須容錯**：真實的 `File.delete` 對已經不存在的
///   檔案會丟 `PathNotFoundException`（`FileSystemException`），對被鎖住／
///   唯讀的檔案也可能丟 `FileSystemException`。store 實現**不需要**保證
///   `remove` 冪等或不拋錯；`UploadQueue` 自己吞掉這些失敗（只回報），
///   所以「刪不掉」永遠不會變成「送不出去」或「整個 flush 中斷」。
abstract interface class FrameStore {
  Future<List<String>> pendingPaths();

  Future<void> remove(String path);
}

/// 上傳隊列：**先落盤、後送出、失敗保留**。
///
/// ## 幾個刻意的決定
///
/// 1. **訪客／離線不送出**：`FeatureGate` 不允許時 `flush()` 直接返回 0，
///    素材留在本機。這不是錯誤，所以**不丟例外**——呼叫方不該把它當故障處理，
///    也不該因此彈窗或降級核心功能。
/// 2. **去重鍵用檔案路徑**（偏離 spec §5 的 sha256）：`dart:core` 沒有 sha256，
///    加 `crypto` 會多一個依賴、走原生通道會多一條平台契約；而素材檔名由我們
///    自己產生，路徑本來就唯一。之後若允許 `crypto`，只換 `_keyFor` 即可。
///    **刻意不加 idempotency key**：不在 `UploadFrameRequest`／`PathGuideApi`
///    上新增欄位。
/// 3. **可重試的失敗保留，不可重試的停止重試**：本類別不做定時器，由呼叫方
///    （畫面或前景服務）決定何時 `flush()`。`ApiFailure.retryable == true` 的
///    項目留在 store 裡，下次 `flush()` 再試一次；`false` 的（含 `auth_expired`
///    ——本版還沒有 refresh 流程）再試一百次也是同一個結果，所以移出 store
///    並回報，否則隊列會永遠卡在同一筆、而且每次 flush 都重打一次伺服器。
/// 4. **重複上傳：客戶端擋不住，只能靠人工複核**。隊列**只按本機檔案路徑**
///    去重（`_keyFor`）。一次「位元組已經到了伺服器、客戶端卻只看到逾時」的
///    上傳，下次 `flush()` 仍會把同一幀再送一遍 → 伺服器端可能多出一幀
///    **重複素材**。客戶端沒有任何機制能阻止它：這裡送出的
///    `UploadFrameRequest.routeId` 從不填（永遠 `null`），`capturedAt` 是這一
///    幀檔案的修改時間（重試時穩定，但它只是「檔案寫下來的時刻」的代理值，
///    不是拍攝證明），所以這兩個欄位都不是可以拿來去重的識別鍵。這種重複必須
///    由**伺服器端去重（尚未實作）或人工複核（Spec 6）**發現。寧可多一幀
///    待審素材，也不為此新增一條未經驗證的客戶端密鑰契約。
/// 5. **`flush()` 是全函式（total）**：`FrameStore`／`PathGuideApi`／`token`／
///    `gate` 的任何失敗都不會從 `flush()` 冒出去（`ApiFailure` 以外也不行），
///    而且失敗只影響那一項——一筆壞素材不會讓後面整批都不送。回報用的
///    `onError` 自己拋錯也一樣：那道保護在 `_report` 裡。
class UploadQueue {
  UploadQueue({
    required this.api,
    required this.store,
    required this.gate,
    required this.token,
    this.maxItems = defaultMaxItems,
    Future<String> Function()? modelVersionProvider,
    this.onError,
  }) : _modelVersionProvider = modelVersionProvider ?? _loadBundledModelVersion;

  static const int defaultMaxItems = 500;

  /// 讀不到發布清單時要報的模型版本。
  ///
  /// 以前這是**唯一**會送出的值（`'local'`），於是每一幀都告訴伺服器「這是
  /// 本機模型跑的」，即使端上明明有一份帶版本的清單。現在它只是降級值：
  /// 誠實的「不知道」，不是編出來的版本號。
  static const String fallbackModelVersion = 'local';

  final PathGuideApi api;
  final FrameStore store;
  final FeatureGate Function() gate;
  final String Function() token;

  /// 隊列上限。目的是「不讓本機素材無限長大」而不是「保住全部」。
  final int maxItems;

  /// 上傳時要報的模型版本來源。預設讀端上**已發布**的清單。
  ///
  /// 清單（`assets/models/detector.json`）是模型的下發單位——它與 .tflite
  /// 一起產生、一起發布，所以它的 `version` 才是「這一幀是哪個模型跑的」。
  /// 以前這裡硬寫 `'local'`，等於每一幀都丟掉伺服器唯一需要的資訊。
  ///
  /// 留成可注入的函式：測試不該依賴 `rootBundle`（那是 Flutter 的資源通道，
  /// 純邏輯測試沒有它），而換版本來源（例如改成跟 `LocalOnlyApi` 共用一個
  /// 實例）時也不必動這支檔案。
  final Future<String> Function() _modelVersionProvider;

  /// 容錯路徑的回報點（刪檔失敗、store 列舉失敗、`token()`／`gate()` 失敗、
  /// 不可重試的失敗、被 trim 丟掉的素材、契約外錯誤）。
  ///
  /// 為什麼是回呼而不是直接寫 log：本層沒有可用的日誌工具——`dart:core` 沒有
  /// logger，`debugPrint` 在 `flutter/foundation`，而這支檔案碰 Flutter 只有
  /// 為了讀端上清單的 `rootBundle`（見 [_loadBundledModelVersion]），不該再為了
  /// 一行訊息把整個邏輯層綁上 framework 或用例。所以把「怎麼記」交給呼叫方：
  /// Flutter 層接上 `debugPrint`，測試接上一個記錄陣列。
  /// **預設 `null`＝靜默**，也就是這裡的容錯預設不會影響既有呼叫方。
  ///
  /// ★ 處理器自己拋錯不會逃出去（見 [_report]）。
  final void Function(String message, Object error)? onError;

  /// 這個 process 內已成功送出的去重鍵。
  ///
  /// 只存在記憶體：app 重啟後會回到空集合。這是可接受的，因為送出成功後
  /// 立即 `store.remove(path)`；`_sent` 真正要擋的是「送了、但刪檔失敗」那條
  /// 少見路徑，以及同一次 run 內 `pendingPaths()` 又回報同一個路徑的情形。
  /// 命中 `_sent` 的項目**只補刪、不重送、也不計入回傳張數**（它上一次已經
  /// 被算過了），這樣「已上傳的幀」在整個 process 內剛好被計一次。
  final Set<String> _sent = <String>{};

  String _keyFor(String path) => path;

  /// 讀端上發布清單的版本號（`modelVersionProvider` 的預設值）。
  ///
  /// 與 `local_only_api.dart` 走**同一條**路徑、同一個解析器：清單的格式只有
  /// 一處定義（`vision/model_manifest.dart`），這裡不重複解釋它。
  /// 讀不到／解析不出來就拋：降級成 [fallbackModelVersion] 是呼叫方
  /// （[_modelVersion]）的決定，這裡不假裝成功。
  static Future<String> _loadBundledModelVersion() async {
    final parsed =
        parseModelManifest(await rootBundle.loadString(defaultModelManifestKey));
    final manifest = parsed.manifest;
    if (manifest == null) {
      throw StateError('模型清單無法解析：${parsed.error}');
    }
    return manifest.version;
  }

  /// 這一輪要報的模型版本。讀不到就回 [fallbackModelVersion]（並回報）。
  Future<String> _modelVersion() async {
    try {
      final version = await _modelVersionProvider();
      if (version.isNotEmpty) return version;
      // 空字串對伺服器等於「有送這個欄位但沒有內容」，分不出「沒有版本」與
      // 「欄位漏了」——所以當成讀不到處理，跟缺欄位的語義保持一致。
      _report(
        '模型版本是空字串，改用 $fallbackModelVersion',
        StateError('empty model version'),
      );
    } catch (error) {
      _report('讀取模型版本失敗，改用 $fallbackModelVersion', error);
    }
    return fallbackModelVersion;
  }

  /// 這一幀的「拍攝時刻」。
  ///
  /// 以前是 `DateTime.now()`——那是 **flush 的時刻**，不是拍攝時刻；重試一次
  /// 就換一個時間，於是每一幀的重試看起來都像新素材。改成檔案自己的修改時間
  /// （`File.statSync().modified`）：那是「它被寫下來的時刻」，也是目前唯一
  /// 一個每幀穩定、又不需要新增欄位的代理值。
  ///
  /// 誠實註明：這是**代理值**，不是 EXIF／相機時戳——若之後錄製端能給真的
  /// 拍攝時間，應該由它在入隊時寫進檔名或 sidecar，而不是在這裡猜。
  ///
  /// 讀不到（無 stat 權限、非 `dart:io` 平台）就退回 now()；這裡**不**回報：
  /// 時間讀不到不影響「這一幀要不要送」。
  ///
  /// ★ **「檔案已經不在」在這裡不會丟例外**，以前那句「讀不到就退回 now()」
  ///   是錯的：實測（本機以探針跑過）對一個**不存在的**路徑呼叫
  ///   `File(path).statSync()` **不拋**，而是回一份「零化」的 stat——`modified`
  ///   是 `1970-01-01T00:00:00.000Z`（epoch，與當下相差約 -497984 小時）。
  ///   於是 `catch` 那條退回路徑**從來不會執行**，每一幀「檔案已不在」的素材
  ///   都會帶著 `capturedAt = 1970` 送出，伺服器看到的拍攝時刻是 1970 年。
  ///
  ///   所以這裡用兩道檢查，任一不過就退回 now()：
  ///   1. 先 `existsSync()`：路徑不存在就**根本不去 stat**（不依賴 stat 會拋）；
  ///   2. stat 回來的 `modified` 若不是正數（epoch 或更早）也視為讀不到
  ///      ——平台有可能用「給一份零化的 stat」代替拋例外，沒有一個真實檔案的
  ///      mtime 會是 epoch，那個值的意思就是「沒有時間」。
  static DateTime _capturedAt(String path) {
    final file = File(path);
    try {
      if (file.existsSync()) {
        final modified = file.statSync().modified;
        if (modified.millisecondsSinceEpoch > 0) return modified.toUtc();
      }
    } catch (_) {
      // 無 stat 權限（或非 `dart:io` 平台的怪失敗）：走下面的降級。
    }
    return DateTime.now().toUtc();
  }

  void _report(String message, Object error) {
    final handler = onError;
    if (handler == null) return;
    try {
      handler(message, error);
    } catch (_) {
      // ★ `onError` 是呼叫方給的函式，它自己拋錯**不可以**逃出去：
      //   `flush()`／`trim()` 的契約是「全域容錯」，而這句話是唯一守得住
      //   那道契約的地方。以前這裡是裸呼叫，處理器一拋就衝出 flush，
      //   而且是在「已經回報失敗」的路上拋——呼叫方只看到例外，看不到失敗。
    }
  }

  /// 丟掉超出上限的最舊項目（`pendingPaths()` 需按時間升序回傳）。
  ///
  /// 公開是為了讓呼叫方（例如錄完一段路線後）能立刻收斂，不必等下一次 flush。
  /// 和 `flush()` 一樣容錯：列舉失敗就整批跳過，單筆刪失敗就繼續刪下一筆。
  Future<void> trim() async {
    final List<String> paths;
    try {
      paths = await store.pendingPaths();
    } catch (error) {
      _report('讀取待上傳清單失敗，本次 trim 略過', error);
      return;
    }
    if (paths.length <= maxItems) return;
    final excess = paths.length - maxItems;
    // 先回報、再刪：被 trim 掉的素材是**不可逆**的損失，沒有任何紀錄就等於
    // 它從未存在過。以前這裡是無聲的——`onError` 預設 null，而且從來沒有被
    // 叫到，於是「本機素材變少」是唯一的痕跡（而看不見的使用者看不到它）。
    _report(
      '隊列超過上限（$maxItems），將丟棄最舊的 $excess 項素材'
      '（共 ${paths.length} 項）',
      StateError('trim 丟棄 $excess 項：${paths.take(excess).join(', ')}'),
    );
    for (var i = 0; i < excess; i++) {
      await _removeQuietly(paths[i]);
    }
  }

  /// 送出所有待上傳項目，回傳成功張數。
  ///
  /// 門禁不允許時回 0 且**不拋例外**（訪客是合法狀態，不是故障）。
  ///
  /// 契約：**不讓任何非 `ApiFailure` 的錯誤逃出去**（`ApiFailure` 也不會）。
  /// `_sent` 命中的補刪、單項上傳、刪檔各自被隔離，所以一次 flush 不會因為
  /// 一筆壞素材就中止其餘項目，也不會在之後的每次都重拋同一個錯而卡死隊列。
  Future<int> flush() async {
    // `gate` 和 `token` 一樣是呼叫方給的函式，它自己拋錯也一樣要被隔離：
    // 以前這裡是裸的 `gate().allows(...)`，閉包一拋就在**第一個 await 之前**
    // 從 flush 冒出去，和 `token()` 已有的保護不對稱，也推翻了「flush 全域
    // 容錯」這條契約。
    //
    // 讀不到門禁就當成「不允許」：寧可這一輪什麼都不送（素材留在本機、下次
    // 再試），也不要在不知道能不能送的時候把素材送出去。
    final FeatureGate current;
    try {
      current = gate();
    } catch (error) {
      _report('讀取能力門禁失敗，本次 flush 略過', error);
      return 0;
    }
    if (!current.allows(CloudCapability.uploadFrames)) return 0;

    await trim();

    final List<String> paths;
    try {
      paths = await store.pendingPaths();
    } catch (error) {
      // 列舉失敗時連「哪些已送出」都無法得知：這一輪當成 0 張，
      // 留在 store 的素材下次再試（寧可少報，也不讓例外冒出去）。
      _report('讀取待上傳清單失敗，本次 flush 略過', error);
      return 0;
    }

    var sent = 0;
    // token 只在真的要上傳時取一次：純補刪的 flush 不需要它，而
    // `token()` 是呼叫方提供的函式，它自己拋錯也一樣要被隔離（見下）。
    var authToken = '';
    var tokenTaken = false;
    var tokenFailed = false;
    // 模型版本同理：一輪 flush 只讀一次清單（同一批素材同一個版本）。
    var modelVersion = '';

    for (final path in paths) {
      if (_sent.contains(_keyFor(path))) {
        // 已送出（上次送出後刪檔失敗）→ 只補刪，不重送、不重複計數。
        await _removeQuietly(path);
        continue;
      }
      if (tokenFailed) continue;

      if (!tokenTaken) {
        try {
          authToken = token();
          tokenTaken = true;
        } catch (error) {
          // 拿不到 token 就整批送不了：回報一次，留住所有項目，回 0。
          // 不在迴圈裡反覆重試同一個必敗的呼叫。
          _report('取得存取權杖失敗，本次 flush 略過', error);
          tokenFailed = true;
          continue;
        }
      }

      // 清單讀不到時 `_modelVersion()` 自己降級並回報，不會拋。
      if (modelVersion.isEmpty) modelVersion = await _modelVersion();

      try {
        await api.uploadFrame(
          token: authToken,
          request: UploadFrameRequest(
            framePath: path,
            // 檔案修改時間（代理的拍攝時刻），不是 flush 的時刻。
            capturedAt: _capturedAt(path),
            modelVersion: modelVersion,
          ),
        );
        // ★ 先記成功、先計數，才碰本機檔案：刪檔失敗不能讓「已到伺服器
        //   的這一幀」變成沒被算過（否則之後每次都走 _sent 補刪分支，
        //   回傳張數永久的少 1）。
        _sent.add(_keyFor(path));
        sent++;
        await _removeQuietly(path);
      } on ApiFailure catch (failure) {
        // ★ 以前這裡是無條件的 `continue`：不看 `retryable`、也不回報。
        //   於是「不可重試」的失敗（伺服器說這一幀不合法、檔案缺了、格式
        //   不對）永遠留在隊列裡，每次 flush 都重打一個**註定失敗**的請求，
        //   而且一句話都不說——素材在，但永遠送不出去，也沒有任何紀錄。
        //
        //   例外一筆：`auth_expired` 在契約裡是**可重試**的（重登後再試），
        //   但本版**還沒有 refresh 流程**，重試只會拿同一份過期令牌空轉。
        //   所以它在隊列裡一律當成不可重試：停止重試並回報，等 refresh
        //   真的做出來再改回「留著、等新令牌」。
        if (failure.retryable && failure.code != 'auth_expired') {
          // 暫時性失敗：留著，下一次 flush 再試。這裡不刪、不回報成錯誤
          // ——素材還在，下次會再送一次，訊息會是重複的噪音。
          continue;
        }
        // 不可重試：移出 store（走既有的補刪路徑），並讓它留下紀錄。
        _report(
          '上傳 ${_keyFor(path)} 失敗且不可重試，已停止重試這一筆：'
          '${failure.code} ${failure.message}',
          failure,
        );
        await _removeQuietly(path);
        continue;
      } catch (error) {
        // api 實現拋了契約外的型別（沒被包成 ApiFailure）：仍然只是「這一項
        // 失敗」，留住素材、繼續送其餘項目——一筆壞素材不該讓整批停擺。
        _report('上傳 ${_keyFor(path)} 失敗（非 ApiFailure，已隔離）', error);
        continue;
      }
    }
    return sent;
  }

  /// 刪本機素材，**任何失敗都吞掉**（只回報）。
  ///
  /// 典型失敗是 `PathNotFoundException`／`FileSystemException`（檔案已經不在、
  /// 或被鎖住）——「已經不在了」對隊列來說正是想要的結果。刪不掉也**不影響
  /// 這一幀已經上傳成功**的事實：它已記進 `_sent`，不會被重送，也不會被
  /// 重複計數。這裡刻意不逐一列出例外型別：`catch` 全收就已經涵蓋
  /// `FileSystemException`，也涵蓋 store 實現自己丟的怪東西。
  Future<void> _removeQuietly(String path) async {
    try {
      await store.remove(path);
    } catch (error) {
      _report('刪除本機素材失敗（已忽略）', error);
    }
  }
}
