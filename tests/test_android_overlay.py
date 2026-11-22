"""Android overlay 是否已套用的静态门禁。

## 为什么需要这条测试

本仓库的 App 基线跟上游（actiondarr/pathguide）走，每次同步上游都会覆盖或删除
本仓库专属的 Android 工作（菜單 OCR、快速設定磁貼、四語系 app_name、菜單頁的
第三方語音廠商名、以及非 macOS 的 Keychain 平台守衛）。

这些工作由 `scripts/apply_android_overlay.ps1` 幂等重放。**脚本存在不等于脚本跑过**：
同步上游后忘了跑，磁贴会静默消失、菜單入口在 Android 上不见、四个路線記憶測試會在
Windows 上全红——三种都不会有人主动报错。

所以这里用静态检查把「已套用」钉成不变量（刻意不用 subprocess 调用脚本：本仓库的运行
沙箱会拒绝带管道的子进程）。

维护方式：新增一项 overlay 内容时，同时在这里加一条断言。
"""

from __future__ import annotations

from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "apply_android_overlay.ps1"
APP = REPO_ROOT / "app"
ANDROID = APP / "android" / "app" / "src" / "main"

# overlay 自带的新增档（上游没有，同步后必须由脚本还原）
OVERLAY_FILES = [
    ANDROID / "kotlin/hk/pathguide/pathguide/MenuPlugin.kt",
    ANDROID / "kotlin/hk/pathguide/pathguide/PathGuideTileService.kt",
    ANDROID / "res/drawable/ic_qs_tile.xml",
    ANDROID / "res/xml/file_paths.xml",
    ANDROID / "res/values/strings.xml",
    ANDROID / "res/values-zh-rCN/strings.xml",
    ANDROID / "res/values-zh-rHK/strings.xml",
    ANDROID / "res/values-zh-rTW/strings.xml",
    APP / "test/menu_platform_test.dart",
    APP / "test/android_back_test.dart",
    ANDROID / "kotlin/hk/pathguide/pathguide/CameraPreprocess.kt",
    ANDROID / "kotlin/hk/pathguide/pathguide/RouteCameraPlugin.kt",
    ANDROID / "kotlin/hk/pathguide/pathguide/RouteLandmarkPlugin.kt",
    APP / "android/app/src/test/kotlin/hk/pathguide/pathguide/CameraPreprocessTest.kt",
    APP / "assets/models/route_landmark_embedder.tflite",
    APP / "assets/models/route_landmark_embedder.json",
    APP / "lib/route_memory/route_platform_profile.dart",
    APP / "lib/route_memory/route_camera_preview.dart",
    APP / "test/route_android_profile_test.dart",
]

# (档案, 说明, 该出现的「已套用」标记)
PATCH_MARKERS = [
    (
        ANDROID / "kotlin/hk/pathguide/pathguide/MainActivity.kt",
        "MainActivity 注册菜單插件",
        "flutterEngine.plugins.add(menuPlugin)",
    ),
    (
        ANDROID / "kotlin/hk/pathguide/pathguide/MainActivity.kt",
        "MainActivity 转发 onActivityResult",
        "menuPlugin.onActivityResult(requestCode, resultCode, data)",
    ),
    (
        ANDROID / "AndroidManifest.xml",
        "manifest label 走资源",
        'android:label="@string/app_name"',
    ),
    (
        ANDROID / "AndroidManifest.xml",
        "manifest 快速設定磁貼 service",
        ".PathGuideTileService",
    ),
    (
        ANDROID / "AndroidManifest.xml",
        "manifest FileProvider",
        "androidx.core.content.FileProvider",
    ),
    (
        APP / "android/app/build.gradle.kts",
        "gradle ML Kit 中文辨識",
        "text-recognition-chinese:16.0.1",
    ),
    (
        APP / "lib/menu/menu_reader.dart",
        "menu_reader 纳入 Android",
        "TargetPlatform.android);",
    ),
    (
        APP / "lib/menu/menu_reader.dart",
        "menu_reader 不支援时的说明",
        "菜單閱讀目前支援 iPhone 與 Android。",
    ),
    (
        APP / "lib/menu/menu_page.dart",
        "菜單頁廠商名純函數",
        "String onlineVoiceVendorFor(TargetPlatform platform)",
    ),
    (
        APP / "lib/menu/menu_page.dart",
        "菜單頁標題用廠商名",
        "_onlineVoiceVendor()} 線上語音搜尋？",
    ),
    (
        APP / "lib/menu/menu_page.dart",
        "菜單頁不支援时的理由",
        "AppText(_unsupportedReason(widget.generalReading))",
    ),
    (
        APP / "android/app/src/main/kotlin/hk/pathguide/pathguide/MenuPlugin.kt",
        "Android 菜單插件回傳通用讀字的 readingLines",
        'payload["readingLines"] = lines',
    ),
    (
        APP / "android/app/src/main/kotlin/hk/pathguide/pathguide/MenuPlugin.kt",
        "菜單插件只回覆仍是當前的請求（防 Reply already submitted 崩潰）",
        "if (readReply !== reply) return@recognize",
    ),
    (
        APP / "android/app/src/main/kotlin/hk/pathguide/pathguide/VisionPlugin.kt",
        "推理與釋放互斥（防推理中 close 的 SIGSEGV）",
        "if (closed) runCatching { interpreter.close() }",
    ),
    (
        APP / "lib/menu/menu_page.dart",
        "回前景途中的 hidden 不當成離開",
        "_lastLifecycle == AppLifecycleState.paused;",
    ),
    (
        APP / "lib/ui/app_shell.dart",
        "系統返回鍵與左上角返回箭頭一致（只有首頁交還系統）",
        "onPopInvokedWithResult: (didPop, _) {",
    ),
    (
        APP / "android/app/src/main/kotlin/hk/pathguide/pathguide/VisionPlugin.kt",
        "檢測前處理改用與離線評估一致的 CameraPreprocess",
        "CameraPreprocess.letterbox(",
    ),
    (
        APP / "android/app/src/main/kotlin/hk/pathguide/pathguide/MainActivity.kt",
        "註冊 Android 錄路相機與路標特徵插件",
        "flutterEngine.plugins.add(RouteLandmarkPlugin(this))",
    ),
    (
        APP / "lib/route_memory/route_package.dart",
        "已錄路線相容性按平台特徵配置判斷（不再寫死 iOS）",
        "RoutePlatform.feature.featureRevision",
    ),
    (
        APP / "test/menu_ui_test.dart",
        "菜單測試斷言當前平台廠商名",
        "final vendor = onlineVoiceVendorFor(defaultTargetPlatform);",
    ),
    (
        APP / "test/menu_ui_test.dart",
        "菜單測試廠商名三分支",
        "線上語音的廠商名：iOS=Apple",
    ),
]

# route_memory 在 Windows 上的兩件事（都修程式，不跳測試；POSIX 上是 no-op）：
#   (a) `.lock` 用路徑末段判斷
#   (b) 孤兒清理按平台分隔符比對 keep 集合
# 2026-11-22 查證：之前 Windows 跳過的 8 條測試，真因是 (b)，不是「不能刪除已打開的 .lock」。
ROUTE_STORE = APP / "lib/route_memory/encrypted_route_store.dart"
LEARNING_STORE = APP / "lib/route_memory/route_learning_store.dart"
ROUTE_STORES = [ROUTE_STORE, LEARNING_STORE]


def test_overlay_script_exists():
    assert SCRIPT.exists(), "缺少 scripts/apply_android_overlay.ps1（同步上游后无法重放 Android 工作）"


def test_overlay_script_is_utf8_with_bom():
    """Windows PowerShell 5.1 只认带 BOM 的 UTF-8。

    没有 BOM 时脚本里的中文锚点会被按 ANSI 解码，锚点全部匹配不到——症状是
    「脚本跑完了，但什么都没改」，而且退出码看起来正常。
    """
    head = SCRIPT.read_bytes()[:3]
    assert head == b"\xef\xbb\xbf", "脚本应是 UTF-8 with BOM"


@pytest.mark.parametrize("path", OVERLAY_FILES, ids=lambda p: p.name)
def test_overlay_file_present(path: Path):
    assert path.exists(), (
        f"{path.relative_to(REPO_ROOT)} 不存在：同步上游后要跑 "
        "scripts/apply_android_overlay.ps1"
    )


@pytest.mark.parametrize(
    "path,label,marker",
    PATCH_MARKERS,
    ids=[f"{p.name}:{label}" for p, label, _ in PATCH_MARKERS],
)
def test_overlay_patch_applied(path: Path, label: str, marker: str):
    assert path.exists(), f"{path.relative_to(REPO_ROOT)} 不存在"
    text = path.read_text(encoding="utf-8")
    assert marker in text, (
        f"{path.relative_to(REPO_ROOT)} 缺少「{label}」的标记 {marker!r}："
        "同步上游后要跑 scripts/apply_android_overlay.ps1"
    )


def test_route_store_lock_path_is_platform_safe():
    """`.lock` 必須用**路徑末段**判斷，不能比對 `'/.lock'`。

    Windows 的 `File.path` 用反斜線，`'...\\.lock'.endsWith('/.lock')` 恆為 false，
    於是鎖檔被當成「已有資料但沒有金鑰」→ 每次開檔都 `RouteStoreFailure(keyUnavailable)`。
    這個 bug 在 Android／iOS（POSIX）看不到，只有 Windows 開發機才會撞到，
    所以特別容易被誤判成「需要 Keychain」而用 skip 蓋掉（本倉庫真的這樣誤判過一次）。
    """
    assert ROUTE_STORE.exists()
    text = ROUTE_STORE.read_text(encoding="utf-8")
    assert "name != '.lock'" in text, "應改用路徑末段判斷鎖檔"
    # 只看**程式碼**那一種寫法（註解裡正好引用了錯誤寫法作為說明，不能一起判死）
    assert "if (f is File && !f.path.endsWith('/.lock')) {" not in text, (
        "舊的鎖檔判斷又回來了：Windows 反斜線會讓它恆為 false"
    )


@pytest.mark.parametrize("path", ROUTE_STORES, ids=lambda p: p.name)
def test_learning_and_route_store_lock_path_is_platform_safe(path: Path):
    """兩個 store 都不能再用 `endsWith('/.lock')` 判斷鎖檔（route_learning_store 是上游 1.12 新增的同款 bug）。"""
    text = path.read_text(encoding="utf-8")
    assert "!f.path.endsWith('/.lock')) {" not in text
    assert "!e.path.endsWith('/.lock')))" not in text


@pytest.mark.parametrize("path", ROUTE_STORES, ids=lambda p: p.name)
def test_orphan_cleanup_compares_native_paths(path: Path):
    """孤兒清理的 keep 集合用 '/' 拼，必須轉成平台分隔符再比對。

    否則 Windows 上要保留的紀錄與 .lock 全被當孤兒刪掉（POSIX 看不到）。
    """
    text = path.read_text(encoding="utf-8")
    assert "final keepNative = {" in text
    assert "!keepNative.contains(f.path)" in text
    assert "!keep.contains(f.path)) await f.delete();" not in text


@pytest.mark.parametrize(
    "rel",
    ["test/captured_route_store_test.dart", "test/encrypted_route_store_test.dart"],
)
def test_route_store_tests_are_not_skipped_on_windows(rel: str):
    """跳過已撤銷：程式修好後這些測試在 Windows 上也要真跑。"""
    text = (APP / rel).read_text(encoding="utf-8")
    assert "destructiveTest(" not in text
    assert "_winLockSkip" not in text
