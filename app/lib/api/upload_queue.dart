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
/// 3. **失敗保留但不無限重試**：本類別不做定時器，由呼叫方（畫面或前景服務）
///    決定何時 `flush()`。失敗的項目留在 store 裡，下次 `flush()` 再試一次。
/// 4. **重複上傳：客戶端擋不住，只能靠人工複核**。隊列**只按本機檔案路徑**
///    去重（`_keyFor`）。一次「位元組已經到了伺服器、客戶端卻只看到逾時」的
///    上傳，下次 `flush()` 仍會把同一幀再送一遍 → 伺服器端可能多出一幀
///    **重複素材**。客戶端沒有任何機制能阻止它：這裡送出的
///    `UploadFrameRequest.routeId` 從不填（永遠 `null`），`capturedAt` 是
///    flush 當時才 `DateTime.now()` 生成的（每次重試都不同），所以這兩個欄位
///    都不是「每幀穩定」的識別，拿它們去重是去不掉的。這種重複必須由
///    **伺服器端去重（尚未實作）或人工複核（Spec 6）**發現。寧可多一幀
///    待審素材，也不為此新增一條未經驗證的客戶端密鑰契約。
/// 5. **`flush()` 是全函式（total）**：`FrameStore`／`PathGuideApi`／`token`
///    的任何失敗都不會從 `flush()` 冒出去（`ApiFailure` 以外也不行），而且
///    失敗只影響那一項——一筆壞素材不會讓後面整批都不送。
class UploadQueue {
  UploadQueue({
    required this.api,
    required this.store,
    required this.gate,
    required this.token,
    this.maxItems = defaultMaxItems,
    this.onError,
  });

  static const int defaultMaxItems = 500;

  final PathGuideApi api;
  final FrameStore store;
  final FeatureGate Function() gate;
  final String Function() token;

  /// 隊列上限。目的是「不讓本機素材無限長大」而不是「保住全部」。
  final int maxItems;

  /// 容錯路徑的回報點（刪檔失敗、store 列舉失敗、`token()` 失敗、契約外錯誤）。
  ///
  /// 為什麼是回呼而不是直接寫 log：本層和 `http_transport.dart` 一樣**刻意不
  /// import Flutter**（拿不到 `debugPrint`），而 `dart:core` 沒有 logger。硬要
  /// log 就得為此把純邏輯層綁上 framework，或為一行訊息引入依賴。所以把
  /// 「怎麼記」交給呼叫方：Flutter 層接上 `debugPrint`，測試接上一個記錄陣列。
  /// **預設 `null`＝靜默**，也就是這裡的容錯預設不會影響既有呼叫方。
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

  void _report(String message, Object error) {
    final handler = onError;
    if (handler == null) return;
    handler(message, error);
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
    if (!gate().allows(CloudCapability.uploadFrames)) return 0;

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

      try {
        await api.uploadFrame(
          token: authToken,
          request: UploadFrameRequest(
            framePath: path,
            capturedAt: DateTime.now().toUtc(),
            modelVersion: 'local',
          ),
        );
        // ★ 先記成功、先計數，才碰本機檔案：刪檔失敗不能讓「已到伺服器
        //   的這一幀」變成沒被算過（否則之後每次都走 _sent 補刪分支，
        //   回傳張數永久的少 1）。
        _sent.add(_keyFor(path));
        sent++;
        await _removeQuietly(path);
      } on ApiFailure {
        // 失敗就留著，下一次 flush 再試。這裡不彈窗、不吞掉任何東西：
        // 素材還在 store 裡，使用者下次開畫面時會再送一次。
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
  /// 重複計數。這裡刻意不 import `dart:io` 去逐一列出例外型別：`catch` 全收
  /// 就已經涵蓋 `FileSystemException`，也涵蓋 store 實現自己丟的怪東西。
  Future<void> _removeQuietly(String path) async {
    try {
      await store.remove(path);
    } catch (error) {
      _report('刪除本機素材失敗（已忽略）', error);
    }
  }
}
