import 'api_types.dart';

/// 前端唯一的後端門面。**UI 只認這個介面**。
///
/// 三份實現：`LocalOnlyApi`（訪客/離線）、`HttpApi`（真 HTTP）、
/// 以及測試用的 `FakeTransport` 驅動的 `HttpApi`。
/// 換後端時只換實現，UI 一行不改（spec §13 驗收）。
abstract interface class PathGuideApi {
  Future<GuestSession> createGuestSession({
    required String installId,
    required String platform,
    required String locale,
  });

  Future<AuthSession> login({required String method, required String credential});

  Future<AuthSession> refresh({required String token});

  Future<UploadReceipt> uploadFrame({
    required String token,
    required UploadFrameRequest request,
  });

  Future<ModelEnvelope> latestModel();

  Future<Map<String, Object?>> fetchSettings({required String token});

  Future<void> saveSettings({
    required String token,
    required Map<String, Object?> settings,
  });

  /// Spec 4：雲端 VLM 問答。
  Future<Map<String, Object?>> visionQuery({
    required String token,
    required String imageSha256,
    required String question,
    required String locale,
  });

  /// Spec 5：對話式目的地規劃。
  Future<Map<String, Object?>> planRoute({
    required String token,
    required String utterance,
    required String locale,
  });
}
