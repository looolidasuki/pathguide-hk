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
        "AppText(_unsupportedReason())",
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

# 非 macOS 上必须整档跳过的 iOS Keychain 依赖测试
KEYCHAIN_GUARDED = [
    APP / "test/captured_route_store_test.dart",
    APP / "test/encrypted_route_store_test.dart",
    APP / "test/route_journey_page_test.dart",
    APP / "test/route_record_replay_test.dart",
]


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


@pytest.mark.parametrize("path", KEYCHAIN_GUARDED, ids=lambda p: p.name)
def test_keychain_tests_are_platform_guarded(path: Path):
    """这 4 个测试依赖 iOS Keychain，非 macOS 上必然 keyUnavailable。

    没有守卫时 Windows 上会红 40+ 条，把真正的缺陷淹掉；守卫必须存在且写明原因。
    """
    assert path.exists(), f"{path.relative_to(REPO_ROOT)} 不存在"
    text = path.read_text(encoding="utf-8")
    assert "Platform.isMacOS" in text, (
        f"{path.relative_to(REPO_ROOT)} 缺少平台守卫：非 macOS 上会以 "
        "RouteStoreFailure(keyUnavailable) 全数失败"
    )
    assert "iOS Keychain" in text, "守卫要写明「为什么跳过」，不要静默 skip"
