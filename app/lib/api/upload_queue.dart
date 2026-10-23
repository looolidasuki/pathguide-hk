import 'api_types.dart';
import 'feature_gate.dart';
import 'path_guide_api.dart';

/// 待上傳素材的來源。真實實現讀應用私有目錄；測試用記憶體。
///
/// `pendingPaths()` **必須按時間升序**回傳（最舊的在前面）：`trim()` 依這個
/// 假設丟掉「最舊的」，順序反過來就會丟掉剛剛錄的素材。
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
/// 4. **超時重複的已知上限**：一次「送出後超時」的上傳，伺服器可能已經收到
///    位元組，客戶端卻只看到錯誤 → 下一次 `flush()` 會再送一次，於是伺服器端
///    可能多出一幀重複素材。我們**不在客戶端生成 idempotency key**：請求本身
///    已經帶了 `routeId` 與 `capturedAt`，伺服器可以用這兩者做去重；剩下的由
///    人工複核（Spec 6）過濾。寧可多一幀待審素材，也不要為了保證一次而多一條
///    未經驗證的客戶端密鑰契約。
class UploadQueue {
  UploadQueue({
    required this.api,
    required this.store,
    required this.gate,
    required this.token,
    this.maxItems = defaultMaxItems,
  });

  static const int defaultMaxItems = 500;

  final PathGuideApi api;
  final FrameStore store;
  final FeatureGate Function() gate;
  final String Function() token;

  /// 隊列上限。目的是「不讓本機素材無限長大」而不是「保住全部」。
  final int maxItems;

  /// 這個 process 內已成功送出的去重鍵。
  ///
  /// 只存在記憶體：app 重啟後會回到空集合。這是可接受的，因為送出成功後
  /// 立即 `store.remove(path)`；`_sent` 真正要擋的是「送了、但刪檔失敗」那條
  /// 少見路徑，以及同一次 run 內 `pendingPaths()` 又回報同一個路徑的情形。
  final Set<String> _sent = <String>{};

  String _keyFor(String path) => path;

  /// 丟掉超出上限的最舊項目（`pendingPaths()` 需按時間升序回傳）。
  ///
  /// 公開是為了讓呼叫方（例如錄完一段路線後）能立刻收斂，不必等下一次 flush。
  Future<void> trim() async {
    final paths = await store.pendingPaths();
    if (paths.length <= maxItems) return;
    final excess = paths.length - maxItems;
    for (var i = 0; i < excess; i++) {
      await store.remove(paths[i]);
    }
  }

  /// 送出所有待上傳項目，回傳成功張數。
  ///
  /// 門禁不允許時回 0 且**不拋例外**（訪客是合法狀態，不是故障）。
  Future<int> flush() async {
    if (!gate().allows(CloudCapability.uploadFrames)) return 0;

    await trim();
    final paths = await store.pendingPaths();
    var sent = 0;
    for (final path in paths) {
      if (_sent.contains(_keyFor(path))) {
        // 已送出（例如上次送出後刪檔失敗）→ 補刪，不重送。
        await store.remove(path);
        continue;
      }
      try {
        await api.uploadFrame(
          token: token(),
          request: UploadFrameRequest(
            framePath: path,
            capturedAt: DateTime.now().toUtc(),
            modelVersion: 'local',
          ),
        );
        _sent.add(_keyFor(path));
        await store.remove(path);
        sent++;
      } on ApiFailure {
        // 失敗就留著，下一次 flush 再試。這裡不彈窗、不吞掉任何東西：
        // 素材還在 store 裡，使用者下次開畫面時會再送一次。
        continue;
      }
    }
    return sent;
  }
}
