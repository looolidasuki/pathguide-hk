// `UploadQueue` 的行為測試：**訪客不送、成功即刪、失敗保留、不重送、有上限**。
//
// 為什麼每一條都重要：
// 1. 訪客不送 —— 否則「訪客可完整使用」就變成「偷偷上傳」；
// 2. 成功即刪 —— 否則本機素材永遠不減，最後被 trim 丟掉；
// 3. 失敗保留、已送不重送 —— 否則弱網下會把同一幀送無限次；
// 4. 有上限、丟最舊 —— 否則素材目錄會無聲長大直到手機沒空間；
// 5. flush() 是全函式 —— 刪檔／取 token／store 列舉的失敗都不得逃出去，
//    也不得讓一筆壞素材中斷整批（真實 `File.delete` 對已不存在的檔案會丟
//    `PathNotFoundException`，那是常態而不是異常）。
//
// 這裡的 `_RecordingApi` 只實現 `uploadFrame`：其餘 8 個方法透過 `noSuchMethod`
// 在真的被呼叫時才炸，所以「這個測試只碰上傳」是被釘住的，不是靠人眼。
//
// ★ 模型版本：`UploadQueue` 的預設 provider 讀的是 `rootBundle` 的發布清單，
//   那是 Flutter 的資源通道——純 `test()` 沒有 binding 時它會失敗，於是
//   provider 降級成 `fallbackModelVersion`（並回報）。所以這裡的行為測試
//   **不**斷言特定的版本號；要釘住「版本從清單來」的那一條會注入 provider。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/api/api_types.dart';
import 'package:pathguide/api/feature_gate.dart';
import 'package:pathguide/api/path_guide_api.dart';
import 'package:pathguide/api/upload_queue.dart';

class _RecordingApi implements PathGuideApi {
  final List<String> uploaded = <String>[];
  final List<UploadFrameRequest> requests = <UploadFrameRequest>[];
  final Set<String> failing = <String>{};

  /// 每個路徑要拋的**特定** [ApiFailure]（用來分辨可重試／不可重試）。
  final Map<String, ApiFailure> failures = <String, ApiFailure>{};

  /// 每一筆嘗試過的路徑（含失敗的）：用來斷言「不可重試的項目沒有被重打」。
  final List<String> attempted = <String>[];

  /// 拋出**契約外**的錯誤（不是 `ApiFailure`）：用來證明呼叫方仍不會被拖垮。
  final Set<String> exploding = <String>{};

  @override
  Future<UploadReceipt> uploadFrame({
    required String token,
    required UploadFrameRequest request,
  }) async {
    attempted.add(request.framePath);
    final failure = failures[request.framePath];
    if (failure != null) throw failure;
    if (failing.contains(request.framePath)) {
      throw const ApiFailure(code: 'network', message: 'x', retryable: true);
    }
    if (exploding.contains(request.framePath)) {
      throw Exception('傳輸層漏出的非 ApiFailure 錯誤');
    }
    uploaded.add(request.framePath);
    requests.add(request);
    return const UploadReceipt(frameId: 'f', status: 'queued');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryStore implements FrameStore {
  _MemoryStore(this.files);

  final List<String> files;
  final List<String> removed = <String>[];

  @override
  Future<List<String>> pendingPaths() async => List<String>.from(files);

  @override
  Future<void> remove(String path) async {
    files.remove(path);
    removed.add(path);
  }
}

/// 會「刪不掉」的 store：真實的 `File.delete` 對已被刪掉／被鎖住的路徑就是這樣。
///
/// 拋 `FileSystemException`（`PathNotFoundException` 的父型別，同步拋出），
/// 和 `dart:io` 的行為一致：它不是 `ApiFailure`，舊的 `flush()` 直接漏出去。
class _ThrowingStore implements FrameStore {
  _ThrowingStore(this.files, {this.alwaysThrow = false, Set<String>? throwing})
      : throwing = throwing ?? <String>{};

  final List<String> files;
  final bool alwaysThrow;
  final Set<String> throwing;
  final List<String> removed = <String>[];
  final List<String> attempted = <String>[];

  @override
  Future<List<String>> pendingPaths() async => List<String>.from(files);

  @override
  Future<void> remove(String path) async {
    attempted.add(path);
    if (alwaysThrow || throwing.contains(path)) {
      throw FileSystemException('Cannot delete file', path);
    }
    files.remove(path);
    removed.add(path);
  }
}

void main() {
  const signedInOnline =
      FeatureGate(state: SessionState.authenticated, isOnline: true);
  const guest = FeatureGate(state: SessionState.guest, isOnline: true);
  const signedInOffline =
      FeatureGate(state: SessionState.authenticated, isOnline: false);

  test('★ 訪客不上傳（不是靜默失敗，而是根本不排隊送出）', () async {
    final api = _RecordingApi();
    final store = _MemoryStore(<String>['a.jpg']);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => guest,
      token: () => 't',
    );

    expect(await q.flush(), 0);
    expect(api.uploaded, isEmpty);
    expect(store.files, <String>['a.jpg'], reason: '訪客時素材應留在本機');
  });

  test('★ 已登入但離線：同樣回 0、不拋例外、素材留著', () async {
    final api = _RecordingApi();
    final store = _MemoryStore(<String>['a.jpg']);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOffline,
      token: () => 't',
    );

    expect(await q.flush(), 0, reason: '離線不是故障，呼叫方不該看到例外');
    expect(api.uploaded, isEmpty);
    expect(store.files, <String>['a.jpg']);
  });

  test('★ 已登入在線：成功送出的會從本機刪除', () async {
    final api = _RecordingApi();
    final store = _MemoryStore(<String>['a.jpg', 'b.jpg']);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
    );

    expect(await q.flush(), 2);
    expect(api.uploaded, <String>['a.jpg', 'b.jpg']);
    expect(store.files, isEmpty);
    expect(store.removed, <String>['a.jpg', 'b.jpg']);

    // 送出的請求要帶得出「哪一幀、何時拍的、哪個模型版本」，
    // 否則伺服器端無從去重、也無從複核。
    expect(api.requests, hasLength(2));
    for (final req in api.requests) {
      expect(req.modelVersion, isNotEmpty);
      expect(req.capturedAt.isUtc, isTrue);
    }
  });

  test('★ 失敗的留著，下次再送；已送出的不重送（去重）', () async {
    final api = _RecordingApi()..failing.add('b.jpg');
    final store = _MemoryStore(<String>['a.jpg', 'b.jpg']);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
    );

    expect(await q.flush(), 1);
    expect(store.files, <String>['b.jpg']);

    api.failing.clear();
    expect(await q.flush(), 1);
    expect(api.uploaded, <String>['a.jpg', 'b.jpg'], reason: 'a 不該被重送');
    expect(store.files, isEmpty);
  });

  test('失敗的項目不會被記成「已送出」（下次一定還會再試）', () async {
    final api = _RecordingApi()..failing.add('a.jpg');
    final store = _MemoryStore(<String>['a.jpg']);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
    );

    expect(await q.flush(), 0);
    expect(store.files, <String>['a.jpg'], reason: '失敗必須留在本機');

    // 再 flush 一次仍然會嘗試（若失敗被誤記成已送出，這裡會是 0）。
    expect(await q.flush(), 0);
    expect(store.files, <String>['a.jpg']);

    api.failing.clear();
    expect(await q.flush(), 1);
    expect(store.files, isEmpty);
  });

  test('★ 超過上限時丟最舊的，不讓隊列無限長大', () async {
    final api = _RecordingApi();
    final store = _MemoryStore(<String>['1.jpg', '2.jpg', '3.jpg']);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
      maxItems: 2,
    );

    await q.trim();
    expect(store.files, <String>['2.jpg', '3.jpg']);
  });

  test('未超過上限時 trim 什麼都不刪', () async {
    final api = _RecordingApi();
    final store = _MemoryStore(<String>['1.jpg', '2.jpg']);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
      maxItems: 2,
    );

    await q.trim();
    expect(store.files, <String>['1.jpg', '2.jpg']);
    expect(store.removed, isEmpty);
  });

  test('默認上限是 500（spec 的隊列上限，不靠呼叫方記得）', () {
    expect(UploadQueue.defaultMaxItems, 500);
  });

  // ---------- fix round 1：store.remove／token 失敗時 flush() 仍然完整 ----------

  test('★ 其中一個檔案刪不掉：其餘照送、張數照算、第二次 flush 不重送也不拋', () async {
    final api = _RecordingApi();
    final store = _ThrowingStore(
      <String>['a.jpg', 'b.jpg', 'c.jpg'],
      throwing: <String>{'b.jpg'},
    );
    final reported = <String>[];
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
      onError: (message, error) => reported.add(message),
    );

    expect(
      await q.flush(),
      3,
      reason: 'b 的檔案雖然刪不掉，但位元組已經到伺服器了，必須算一張；'
          '更重要的是一次刪檔失敗不得中斷 c —— 舊寫法在這裡整個 flush 拋出去',
    );
    expect(api.uploaded, <String>['a.jpg', 'b.jpg', 'c.jpg'],
        reason: '一筆刪檔失敗不得讓後面的項目被跳過');
    expect(store.files, <String>['b.jpg'], reason: '刪不掉就只能留在本機');
    expect(reported, isNotEmpty, reason: '刪檔失敗要被回報，不是無聲吞掉');

    // 第二次 flush：store 只剩 b，而 b 已在 _sent → 只補刪，補刪又失敗也不拋。
    expect(await q.flush(), 0, reason: '已在伺服器上的一幀不得被重送或重複計數');
    expect(api.uploaded, hasLength(3), reason: 'b 不該被重送');
    expect(store.attempted.where((p) => p == 'b.jpg').length, greaterThanOrEqualTo(2),
        reason: '第二次 flush 確實走到了「補刪」那條分支');
  });

  test('★ 已在 _sent 的項目連兩次刪不掉：flush 每次都正常返回（隊列不卡死）', () async {
    final api = _RecordingApi();
    final store = _ThrowingStore(<String>['a.jpg'], alwaysThrow: true);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
    );

    expect(await q.flush(), 1);
    expect(store.files, <String>['a.jpg']);

    // 走 `_sent` 補刪分支：remove 每次都拋 FileSystemException，不得逃出去。
    expect(await q.flush(), 0);
    expect(await q.flush(), 0);
    expect(api.uploaded, <String>['a.jpg'], reason: '刪不掉不代表要重送');
    expect(store.removed, isEmpty);
  });

  test('★ 刪檔失敗不會讓「已送出」的張數消失（已到伺服器的幀只被算一次）', () async {
    final api = _RecordingApi();
    final store = _ThrowingStore(<String>['a.jpg'], alwaysThrow: true);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
    );

    expect(
      await q.flush(),
      1,
      reason: '舊寫法把 sent++ 放在 store.remove 之後，刪檔一拋就回 0 '
          '—— 等於聲稱一幀明明已經上傳的素材沒送出，而且之後每次都走 _sent 分支，永久少 1',
    );
    expect(await q.flush(), 0, reason: '同一幀第二次 flush 不得再被算一次');
    expect(await q.flush(), 0);
  });

  test('★ token() 拋錯：flush 不讓它逃出去，回 0、素材全留，恢復後照送', () async {
    final api = _RecordingApi();
    final store = _MemoryStore(<String>['a.jpg', 'b.jpg']);
    var tokenBroken = true;
    final reported = <String>[];
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => tokenBroken ? throw Exception('權杖不可用') : 't',
      onError: (message, error) => reported.add(message),
    );

    expect(await q.flush(), 0);
    expect(api.uploaded, isEmpty, reason: '沒有權杖就一個都不該送');
    expect(store.files, <String>['a.jpg', 'b.jpg'], reason: '沒送出去的素材必須留著');
    expect(reported, isNotEmpty, reason: '取權杖失敗要被回報');

    tokenBroken = false;
    expect(await q.flush(), 2);
    expect(store.files, isEmpty);
  });

  test('★ api 拋出契約外的錯誤（非 ApiFailure）：只影響那一項，其餘照送', () async {
    final api = _RecordingApi()..exploding.add('b.jpg');
    final store = _MemoryStore(<String>['a.jpg', 'b.jpg', 'c.jpg']);
    final reported = <String>[];
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
      onError: (message, error) => reported.add(message),
    );

    expect(await q.flush(), 2);
    expect(api.uploaded, <String>['a.jpg', 'c.jpg']);
    expect(store.files, <String>['b.jpg'], reason: '拋錯的那一項要留著，下次再試');
    expect(reported, isNotEmpty);
  });

  test('★ store 列舉失敗：flush 回 0 而不是拋出去', () async {
    final api = _RecordingApi();
    final q = UploadQueue(
      api: api,
      store: _BrokenPendingStore(),
      gate: () => signedInOnline,
      token: () => 't',
      onError: (message, error) {},
    );

    expect(await q.flush(), 0);
    expect(api.uploaded, isEmpty);
    // 公開的 trim() 也一樣容錯。
    await q.trim();
  });

  // ---------- Final fix wave：retryable／trim 紀錄／gate 與 onError 的保護 ----------

  test('★ 不可重試的失敗：停止重試（移出 store）並回報，不是無聲地無限重試', () async {
    final api = _RecordingApi()
      ..failures['a.jpg'] = const ApiFailure(
          code: 'client', message: '這一幀不被接受', retryable: false);
    final store = _MemoryStore(<String>['a.jpg', 'b.jpg']);
    final reported = <String>[];
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
      onError: (message, error) => reported.add(message),
    );

    expect(await q.flush(), 1, reason: 'b 照送；a 不可重試不影響其他項目');
    expect(api.uploaded, <String>['b.jpg']);
    expect(store.files, isEmpty,
        reason: '不可重試的項目要移出 store：留著只會讓隊列永遠卡在同一筆');
    expect(reported.join(' '), contains('不可重試'),
        reason: '停止重試必須留下紀錄，否則等於素材無聲消失');

    // 第二次 flush 不得再打一次那個必敗的請求。
    expect(await q.flush(), 0);
    expect(api.attempted, <String>['a.jpg', 'b.jpg'],
        reason: '不可重試的項目不該被重送（舊寫法每次都重打）');
  });

  test('★ auth_expired 在隊列裡當成不可重試（本版沒有 refresh，重試只會空轉）',
      () async {
    final api = _RecordingApi()
      ..failures['a.jpg'] = const ApiFailure(
          code: 'auth_expired', message: '登入已過期', retryable: true);
    final store = _MemoryStore(<String>['a.jpg']);
    final reported = <String>[];
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
      onError: (message, error) => reported.add(message),
    );

    expect(await q.flush(), 0);
    expect(store.files, isEmpty,
        reason: '同一份過期令牌留著，每次 flush 都只會再拿一次 401');
    expect(reported.join(' '), contains('auth_expired'));

    expect(await q.flush(), 0);
    expect(api.attempted, <String>['a.jpg'],
        reason: '沒有 refresh 流程時重試是空轉，不得無限重試');
  });

  test('★ trim 丟素材前先回報，而且說得出丟了幾項', () async {
    final api = _RecordingApi();
    final store = _MemoryStore(<String>['1.jpg', '2.jpg', '3.jpg']);
    final reported = <String>[];
    var filesAtReport = const <String>[];
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
      maxItems: 2,
      onError: (message, error) {
        reported.add(message);
        // 回報的**當下**素材還在：紀錄不能跟著刪除一起消失。
        filesAtReport = List<String>.from(store.files);
      },
    );

    await q.trim();

    expect(store.files, <String>['2.jpg', '3.jpg']);
    expect(reported, hasLength(1), reason: '一次 trim 只回報一次，不是每項一次');
    expect(reported.single, contains('丟棄'));
    expect(reported.single, contains('1 項'),
        reason: '要說得出丟了幾項（這裡是 1 項）');
    expect(filesAtReport, hasLength(3),
        reason: '必須在刪除**之前**回報：刪完才回報，紀錄可能隨著失敗一起消失');
  });

  test('★ gate() 拋錯：flush 不讓它逃出去，回 0、素材全留', () async {
    final api = _RecordingApi();
    final store = _MemoryStore(<String>['a.jpg', 'b.jpg']);
    final reported = <String>[];
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => throw StateError('門禁不可用'),
      token: () => 't',
      onError: (message, error) => reported.add(message),
    );

    expect(await q.flush(), 0, reason: '門禁讀不到時 flush 仍必須正常返回');
    expect(api.attempted, isEmpty, reason: '不知道能不能送的時候不可以送出去');
    expect(store.files, <String>['a.jpg', 'b.jpg'], reason: '沒送出去的素材要留著');
    expect(reported, isNotEmpty, reason: '門禁失敗要被回報');
  });

  test('★ onError 自己拋錯不會逃出 trim／flush（回報點不得推翻容錯契約）', () async {
    final api = _RecordingApi()
      ..failures['c.jpg'] = const ApiFailure(
          code: 'client', message: 'x', retryable: false);
    final store = _MemoryStore(<String>['a.jpg', 'b.jpg', 'c.jpg']);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
      maxItems: 2,
      onError: (message, error) => throw StateError('記錄器壞了'),
    );

    // trim 會丟 1 項 → 觸發 onError（拋錯）→ 必須被吞掉。
    await q.trim();
    expect(store.files, <String>['b.jpg', 'c.jpg']);

    // flush：c 不可重試 → 再觸發 onError（拋錯）→ 仍然不得逃出去。
    expect(await q.flush(), 1);
    expect(store.files, isEmpty);
  });

  // ---------- Final fix wave：上傳內容要誠實（版本、拍攝時間） ----------

  test('★ modelVersion 取自發布清單（注入的 provider），不是硬寫的 "local"', () async {
    final api = _RecordingApi();
    final store = _MemoryStore(<String>['a.jpg']);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
      modelVersionProvider: () async => '2026-10-02.stage2',
    );

    expect(await q.flush(), 1);
    expect(api.requests.single.modelVersion, '2026-10-02.stage2');
    expect(api.requests.single.modelVersion, isNot('local'),
        reason: '硬寫 "local" 等於告訴伺服器「不知道是哪個模型」');
  });

  test('清單讀不到才回退到 fallbackModelVersion，而且要回報', () async {
    final api = _RecordingApi();
    final store = _MemoryStore(<String>['a.jpg']);
    final reported = <String>[];
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
      modelVersionProvider: () async => throw StateError('清單讀不到'),
      onError: (message, error) => reported.add(message),
    );

    expect(await q.flush(), 1, reason: '版本讀不到不該讓整批上傳停擺');
    expect(api.requests.single.modelVersion, UploadQueue.fallbackModelVersion);
    expect(reported.join(' '), contains('模型版本'), reason: '降級不是靜默的');
  });

  test('modelVersion 是空字串時視同讀不到（不送出空欄位）', () async {
    final api = _RecordingApi();
    final store = _MemoryStore(<String>['a.jpg']);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
      modelVersionProvider: () async => '',
    );

    expect(await q.flush(), 1);
    expect(api.requests.single.modelVersion, UploadQueue.fallbackModelVersion);
  });

  test('★ capturedAt 取檔案修改時間（重試時穩定），不是 flush 當下的時刻', () async {
    final dir = Directory.systemTemp.createTempSync('pathguide_queue_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final frame = File('${dir.path}${Platform.pathSeparator}frame_1.jpg');
    frame.writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);
    // 整秒值：避免檔案系統的次秒精度差異讓這條測試變成平台的擲骰子。
    final modified = DateTime.utc(2026, 10, 23, 4, 5, 6);
    frame.setLastModifiedSync(modified);

    final api = _RecordingApi();
    final store = _MemoryStore(<String>[frame.path]);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
    );

    expect(await q.flush(), 1);
    expect(api.requests.single.capturedAt, modified,
        reason: '以前是 flush 當時的 now()：重試一次就換一個時間，'
            '伺服器無從知道素材是什麼時候拍的');
    expect(api.requests.single.capturedAt.isUtc, isTrue);
  });

  test('★ 路徑存在但**不是一幀檔案**（目錄）時，仍照送且 capturedAt 不是 epoch', () async {
    // 「存在但不是 frame」這一類：`statSync()` 對目錄本身是**成功**的，回的是
    // 目錄的 mtime——一個正值、但**不代表這一幀拍攝時刻**的值。要釘住的性質
    // 只有兩個：這種路徑不會讓上傳被擋掉、也不會把 epoch 帶出去。
    //
    // ★ 為什麼用「剛建立的臨時目錄」而不是套件裡現成的 `test/` 目錄：目錄的
    //   mtime 是「上次有人寫東西進去」的時刻，`test/` 可能是好幾天前。只要
    //   平台讓 `File(目錄).existsSync()` 為真、且 `statSync` 對目錄成功，一個
    //   **正確**的實作就會送出那個舊 mtime——對 `test/` 硬要「大約現在」，
    //   等於把正確的實作判成錯的。臨時目錄在兩種平台語義下都成立：走 stat
    //   分支時值是「剛剛」，走退回 now() 分支時值也是「剛剛」。
    final dir = Directory.systemTemp.createTempSync('pathguide_queue_dir_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    expect(Directory(dir.path).existsSync(), isTrue,
        reason: '前提：${dir.path} 真的是一個存在的目錄');

    final api = _RecordingApi();
    final store = _MemoryStore(<String>[dir.path]);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
    );

    final before = DateTime.now().toUtc();
    expect(await q.flush(), 1,
        reason: '時間讀不到（或讀到怪值）不影響「這一幀要不要送」');
    final after = DateTime.now().toUtc();
    final capturedAt = api.requests.single.capturedAt;
    expect(capturedAt.isUtc, isTrue);
    expect(capturedAt.millisecondsSinceEpoch, greaterThan(0),
        reason: 'epoch（1970-01-01T00:00:00Z）是平台「這裡沒有時間」的訊號，'
            '不是任何一幀的拍攝時刻');

    // 放寬到 ±5s：路徑是目錄時走的是 stat 分支（值＝目錄 mtime，剛建立）或
    // 退回分支（值＝now），兩者都在「剛剛」，但檔案系統的時戳精度可能比
    // 讀數瞬間更粗（FAT 是 2s）。
    const tolerance = Duration(seconds: 5);
    expect(
      capturedAt.isBefore(before.subtract(tolerance)) ||
          capturedAt.isAfter(after.add(tolerance)),
      isFalse,
      reason: 'capturedAt 與 now() 相差 ${capturedAt.difference(before)}'
          '（容許 ±${tolerance.inSeconds}s：目錄不是一幀，值只能是「大約現在」）',
    );
  });

  test('檔案已不在時 capturedAt 退回 now()，不讓時間讀取失敗擋住上傳', () async {
    final api = _RecordingApi();
    // 相對路徑：`flutter test` 的 cwd 是套件根目錄，這個名字保證不存在。
    const missing = 'test/no_such_frame_in_queue.jpg';
    // ★ 前提要明說：這條測的是「路徑不存在 → 退回 `now()`」那條分支。
    //   這一條**不靠** `statSync()` 拋例外才走到退回分支：本機實測 `statSync()`
    //   對不存在的路徑**不拋**，而是回一份零化的 stat（`modified` 是
    //   `1970-01-01T00:00:00Z`）。真正擋下來的是 `_capturedAt()` 裡的
    //   `existsSync()` 與「epoch 視為讀不到」兩道檢查——把任一道拿掉，這條就會
    //   紅在下面的時間窗口上（capturedAt 變成 1970）。
    //   少了這個前提說明，一旦真的存在同名檔案（殘留物、換 cwd），失敗訊息
    //   只會是一句莫名其妙的時間比較，看不出「根本沒走到退回路徑」。
    expect(File(missing).existsSync(), isFalse,
        reason: '這條測試的前提是 $missing 不存在，'
            '否則走的是 mtime 分支，測不到退回路徑');
    final store = _MemoryStore(<String>[missing]);
    final q = UploadQueue(
      api: api,
      store: store,
      gate: () => signedInOnline,
      token: () => 't',
    );

    final before = DateTime.now().toUtc();
    expect(await q.flush(), 1);
    final after = DateTime.now().toUtc();
    final capturedAt = api.requests.single.capturedAt;
    expect(capturedAt.isUtc, isTrue);

    // 要的性質只有一個：**大約現在**。原本寫的「不早於 flush 前的一次讀數」
    // 多要求了一件產品從來沒承諾的事——flush 內的牆鐘讀數必定不早於 flush
    // 外的一次讀數（牆鐘被校時往回跳、或讀數精度比對瞬間更粗都會翻車）。
    // 容差窗口表達的是同一個需求，而且不依賴單調時鐘：epoch 0、舊的
    // flush 時刻、或任何被換掉的陳舊值都遠在窗口外，照樣會紅。
    const tolerance = Duration(seconds: 1);
    final delta = capturedAt.difference(before);
    expect(
      capturedAt.isBefore(before.subtract(tolerance)) ||
          capturedAt.isAfter(after.add(tolerance)),
      isFalse,
      reason: 'capturedAt 與 now() 相差 $delta'
          '（容許 ±${tolerance.inSeconds}s：退回路徑必須是大約現在，'
          '不能是 epoch 0 或某個舊值）',
    );
  });
}

class _BrokenPendingStore implements FrameStore {
  @override
  Future<List<String>> pendingPaths() async {
    throw const FileSystemException('Cannot list directory', '/frames');
  }

  @override
  Future<void> remove(String path) async {}
}
