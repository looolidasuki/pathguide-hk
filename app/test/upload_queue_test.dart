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

  /// 拋出**契約外**的錯誤（不是 `ApiFailure`）：用來證明呼叫方仍不會被拖垮。
  final Set<String> exploding = <String>{};

  @override
  Future<UploadReceipt> uploadFrame({
    required String token,
    required UploadFrameRequest request,
  }) async {
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
}

class _BrokenPendingStore implements FrameStore {
  @override
  Future<List<String>> pendingPaths() async {
    throw const FileSystemException('Cannot list directory', '/frames');
  }

  @override
  Future<void> remove(String path) async {}
}
