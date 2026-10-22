// 移植自上游 `actiondarr/pathguide` 的 `app/test/platform_mapping_test.dart`
// （2026-10-20）。它守的那條不變式是本專案最貴的那類缺陷：
// **模型本地索引被當成專案類別 id** —— 不崩、不報錯，只是每一幀的類名全錯。
//
// 移植時改了兩處：
//
// 1. **映射不再寫死在測試裡。** 上游把 `[11,7,8,50,49,6,9,51,24]`（九類模型）
//    與 `inputSize: 640` 直接抄進測試。本倉庫端上是 18 類 / 416，
//    而模型會被換掉（見 `docs/UPSTREAM-MERGE-ASSESSMENT.md` §4）——
//    寫死的測試會在換模型時變成「要改測試才變綠」，那正是它該防的事。
//    所以這裡改成**從 `assets/models/detector.json` 讀**期望值。
//
// 2. **補上本倉庫特有的「兩步加載」斷言。** 我們的 `initialize()` 先按
//    **空映射**問出模型真實類別數，核對清單無誤後再用真實映射重載一次
//    （`platform_vision.dart` 步驟 4）。上游只有一步，所以它測不到這條。
//
// 未移植的部分（誠實記錄）：上游那條測試還會斷言「驗證完成前到達的幀
// 不會流到 UI」。本倉庫的門禁在**原生**側（`VisionPlugin.analyze()` 開頭
// `if (det == null) return`，且相機只會在模型加載後啟動），Dart 的
// `frames` 不做 `_loaded` 過濾；UI 端是在 `ensureCamera()` 完成後才訂閱，
// 期間的幀因廣播流特性直接丟棄。用 channel mock 模擬「原生提前發幀」
// 等於測一個原生不會做的事，所以那條沒有搬過來。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/vision/model_manifest.dart';
import 'package:pathguide/vision/platform_contract.dart';
import 'package:pathguide/vision/platform_vision.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final binding = TestDefaultBinaryMessengerBinding.instance;

  /// 端上清單是唯一事實源：換模型時這裡自動跟著變，不必改測試。
  late ModelManifest manifest;

  setUpAll(() async {
    final parsed = parseModelManifest(
      await rootBundle.loadString(defaultModelManifestKey),
    );
    expect(parsed.ok, isTrue, reason: '端上模型清單解析失敗：${parsed.error}');
    manifest = parsed.manifest!;
  });

  /// 裝好原生側的假通道；回傳 `loadModel` 收到的 classIds 序列。
  List<Object?> installMocks({
    required int nativeClasses,
    required int inputSize,
    bool loaded = true,
  }) {
    final loadClassIds = <Object?>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(kVisionChannel),
      (call) async {
        switch (call.method) {
          case VisionMethods.startPreview:
            return <String, Object>{'started': true};
          case VisionMethods.modelDir:
            return '/app/files';
          case VisionMethods.fileSize:
            // -1 = 檔案不存在，於是走 writeFile 分支（測試只記錄，不寫盤）。
            return -1;
          case VisionMethods.writeFile:
            return null;
          case VisionMethods.setThreshold:
            return null;
          case VisionMethods.loadModel:
            loadClassIds.add((call.arguments as Map)[VisionKeys.classIds]);
            return <String, Object>{
              VisionKeys.loaded: loaded,
              VisionKeys.classes: loaded ? nativeClasses : 0,
              VisionKeys.inputSize: loaded ? inputSize : 0,
              if (!loaded) VisionKeys.error: '模擬：解釋器建立失敗',
            };
          default:
            return null;
        }
      },
    );
    // EventChannel 的 listen/cancel 也走 method channel：回 null 即可，串流保持安靜。
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(kFrameChannel),
      (_) async => null,
    );
    return loadClassIds;
  }

  void removeMocks() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(kVisionChannel),
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(kFrameChannel),
      null,
    );
  }

  test('★ 清單與模型相符：先空映射問類別數，再用清單映射重載一次', () async {
    final loadClassIds = installMocks(
      nativeClasses: manifest.modelClassCount,
      inputSize: manifest.inputSize,
    );
    final source = PlatformVision();
    try {
      final status = await source.initialize();

      expect(status.ok, isTrue, reason: '狀態訊息：${status.message}');
      expect(source.isReady, isTrue);

      // 兩步加載：第一步必須是**空映射**（否則等於先猜一套映射去讀模型），
      // 第二步才是清單宣告的那套。順序顛倒就說明「先驗證再套用」被破壞了。
      expect(
        loadClassIds,
        <Object?>[
          const <int>[],
          manifest.modelClassIds,
        ],
      );
      expect(source.modelClassCount, manifest.modelClassCount);
      expect(source.classIds, manifest.modelClassIds);
    } finally {
      removeMocks();
    }
  });

  test('★ 原生類別數與清單不符：拒絕啟動，且不再用猜的映射重載', () async {
    final loadClassIds = installMocks(
      nativeClasses: manifest.modelClassCount + 1,
      inputSize: manifest.inputSize,
    );
    final source = PlatformVision();
    try {
      final status = await source.initialize();

      // 寧可顯示「模型與清單不符」，也不要每幀標錯類。
      expect(status.ok, isFalse);
      expect(source.isReady, isFalse);
      expect(
        loadClassIds,
        hasLength(1),
        reason: '核對失敗後不得再用任何映射去重載模型',
      );
      expect(status.message, isNotEmpty);
    } finally {
      removeMocks();
    }
  });

  test('原生回報加載失敗時，initialize 失敗且不留下可用的來源', () async {
    installMocks(
      nativeClasses: manifest.modelClassCount,
      inputSize: manifest.inputSize,
      loaded: false,
    );
    final source = PlatformVision();
    try {
      final status = await source.initialize();
      expect(status.ok, isFalse);
      expect(source.isReady, isFalse);
    } finally {
      removeMocks();
    }
  });

  test('清單自身必須自洽（長度、重複、inputSize）', () {
    expect(manifest.modelClassIds, hasLength(manifest.modelClassCount));
    expect(
      manifest.modelClassIds.toSet(),
      hasLength(manifest.modelClassCount),
      reason: '映射表有重複 id 意味著漏了一類',
    );
    expect(manifest.inputSize, greaterThan(0));
  });
}
