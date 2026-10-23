// `UploadQueue` 的行為測試：**訪客不送、成功即刪、失敗保留、不重送、有上限**。
//
// 為什麼每一條都重要：
// 1. 訪客不送 —— 否則「訪客可完整使用」就變成「偷偷上傳」；
// 2. 成功即刪 —— 否則本機素材永遠不減，最後被 trim 丟掉；
// 3. 失敗保留、已送不重送 —— 否則弱網下會把同一幀送無限次；
// 4. 有上限、丟最舊 —— 否則素材目錄會無聲長大直到手機沒空間。
//
// 這裡的 `_RecordingApi` 只實現 `uploadFrame`：其餘 8 個方法透過 `noSuchMethod`
// 在真的被呼叫時才炸，所以「這個測試只碰上傳」是被釘住的，不是靠人眼。

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/api/api_types.dart';
import 'package:pathguide/api/feature_gate.dart';
import 'package:pathguide/api/path_guide_api.dart';
import 'package:pathguide/api/upload_queue.dart';

class _RecordingApi implements PathGuideApi {
  final List<String> uploaded = <String>[];
  final List<UploadFrameRequest> requests = <UploadFrameRequest>[];
  final Set<String> failing = <String>{};

  @override
  Future<UploadReceipt> uploadFrame({
    required String token,
    required UploadFrameRequest request,
  }) async {
    if (failing.contains(request.framePath)) {
      throw const ApiFailure(code: 'network', message: 'x', retryable: true);
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
}
