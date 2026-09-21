"""构建工具链版本一致性检查。

## 为什么需要它

本项目已经因为**版本组合不兼容**白白失败过多次，而这些失败在跑构建之前
就能全部查出来：

- AGP 9.1.0 + Gradle 9.3.1 + flutter_tts（旧式 Kotlin Gradle Plugin 应用方式）
  -> 构建失败（flutter/flutter#192111、#192167）
- protobuf 7 + TensorFlow 2.19 -> `import tensorflow` 直接失败
- tf_keras 2.15 + TensorFlow 2.19 -> 同样失败
- ultralytics 8.4.x -> 在 Windows 上无法导出 TFLite

**共同点：这些都是可以离线核对的版本约束，不是运行期才发现的问题。**
所以有本脚本：在任何一次构建或导出之前先跑它，而不是靠试。

用法：
    python scripts/check_toolchain_versions.py
    python scripts/check_toolchain_versions.py --json   # 机读输出

退出码 0 表示全部一致；非 0 表示存在会被明确指出的不一致。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
ANDROID_DIR = REPO_ROOT / "app" / "android"
WRAPPER = ANDROID_DIR / "gradle" / "wrapper" / "gradle-wrapper.properties"
SETTINGS = ANDROID_DIR / "settings.gradle.kts"
GRADLE_PROPS = ANDROID_DIR / "gradle.properties"
APP_GRADLE = ANDROID_DIR / "app" / "build.gradle.kts"
PUBSPEC = REPO_ROOT / "app" / "pubspec.yaml"


class Check:
    """一条检查。severity: error 会让退出码非 0。"""

    def __init__(self, name: str, ok: bool, detail: str, severity: str = "error"):
        self.name = name
        self.ok = ok
        self.detail = detail
        self.severity = severity


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def _find(pattern: str, text: str) -> str | None:
    m = re.search(pattern, text, re.MULTILINE)
    return m.group(1) if m else None


def parse_gradle_version() -> str | None:
    return _find(r"gradle-([0-9.]+)-all\.zip", _read(WRAPPER))


def parse_agp_version() -> str | None:
    # 实际写法是：id("com.android.application") version "8.13.2" apply false
    # 注意括号与引号之间还有 `")`，因此不能用 ["\s]+ 这种字符类——
    # 最初就是这么写错的，结果版本解析为 None，检查项**误判通过**。
    return _find(r'id\("com\.android\.application"\)\s*version\s*"([^"]+)"', _read(SETTINGS))


def parse_kotlin_plugin_version() -> str | None:
    return _find(r'id\("org\.jetbrains\.kotlin\.android"\)\s*version\s*"([^"]+)"', _read(SETTINGS))


def parse_flutter_version() -> str | None:
    # 从 SDK 的 version 文件读，避免依赖 flutter 命令
    vf = REPO_ROOT / ".tools" / "flutter" / "version"
    if vf.exists():
        return vf.read_text(encoding="utf-8").strip()
    return None


def parse_litert_dep() -> str | None:
    return _find(r'com\.google\.ai\.edge\.litert:litert:([0-9.]+)', _read(APP_GRADLE))


def parse_camerax_dep() -> str | None:
    return _find(r'val cameraxVersion = "([0-9.]+)"', _read(APP_GRADLE))


def parse_kotlin_jvm_target() -> str | None:
    return _find(r"JvmTarget\.JVM_(\d+)", _read(APP_GRADLE))


def parse_flutter_tts() -> str | None:
    return _find(r"flutter_tts:\s*\^?([0-9.]+)", _read(PUBSPEC))


def major_minor(v: str) -> tuple[int, int]:
    parts = re.findall(r"\d+", v)
    if len(parts) < 2:
        return (int(parts[0]), 0) if parts else (0, 0)
    return (int(parts[0]), int(parts[1]))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    gradle = parse_gradle_version()
    agp = parse_agp_version()
    kotlin = parse_kotlin_plugin_version()
    flutter = parse_flutter_version()
    litert = parse_litert_dep()
    camerax = parse_camerax_dep()
    jvm = parse_kotlin_jvm_target()
    tts = parse_flutter_tts()

    checks: list[Check] = []

    # ---- 0) 解析护栏 ----
    # 任何一个版本解析失败，后面依赖它的检查都会静默"通过"。
    # 本脚本最初就是这样骗过了自己：AGP 正则写错 -> 版本为 None ->
    # 「AGP 与 flutter_tts 兼容」等 4 项全部误判通过。
    # 所以解析失败必须显式报错，而不是跳过。
    for label, value, src in (
        ("Gradle 版本", gradle, WRAPPER),
        ("AGP 版本", agp, SETTINGS),
        ("Kotlin 插件版本", kotlin, SETTINGS),
    ):
        checks.append(Check(
            f"能解析出{label}",
            value is not None,
            f"{value}" if value else f"在 {src.name} 中没匹配到——检查项会因此失去意义，先修正则",
        ))

    # ---- 1) Gradle 版本存在性 ----
    checks.append(Check(
        "Gradle 发行版已声明",
        gradle is not None,
        f"gradle-{gradle}-all.zip" if gradle else f"{WRAPPER} 里没找到 distributionUrl",
    ))

    # ---- 2) AGP 主版本必须与 Gradle 主版本匹配 ----
    if agp and gradle:
        a, g = major_minor(agp), major_minor(gradle)
        if a[0] == 9:
            checks.append(Check(
                "AGP 与 flutter_tts 兼容",
                False,
                f"AGP {agp} 属 9.x，要求所有插件改用 built-in Kotlin；"
                f"flutter_tts {tts} 仍用旧式 Kotlin Gradle Plugin 应用方式，构建会失败"
                f"（flutter/flutter#192111、#192167）。应回退到 AGP 8.13.x",
            ))
        elif a[0] == 8:
            checks.append(Check(
                "AGP 与 flutter_tts 兼容",
                True,
                f"AGP {agp}（8.x）与 flutter_tts {tts} 的旧式 KGP 应用方式兼容",
            ))
        else:
            checks.append(Check("AGP 主版本在预期范围", False, f"AGP {agp} 未在 8.x/9.x 的已知范围"))
        checks.append(Check(
            "Gradle 主版本与 AGP 匹配",
            g[0] == a[0],
            f"Gradle {gradle} / AGP {agp}（同主版本是安全区间）",
        ))

    # ---- 3) AGP 9 专有属性不得残留 ----
    props = _read(GRADLE_PROPS)
    stale = [k for k in ("android.newDsl", "android.builtInKotlin")
             if re.search(rf"^\s*{re.escape(k)}\s*=", props, re.MULTILINE)]
    if stale and agp and major_minor(agp)[0] == 8:
        checks.append(Check(
            "无 AGP 9 专有属性残留",
            False,
            f"gradle.properties 里仍有 {stale}，但 AGP 是 {agp}（8.x）；"
            f"未知 android.* 属性可能导致配置阶段失败",
        ))
    else:
        checks.append(Check("无 AGP 9 专有属性残留", True, "无残留" if not stale else f"{stale}（AGP 9 下正常）"))

    # ---- 4) Kotlin 插件版本与 AGP 主版本 ----
    if kotlin and agp:
        k, a = major_minor(kotlin), major_minor(agp)
        ok = not (a[0] == 8 and k[0] >= 3)
        checks.append(Check(
            "Kotlin 插件与 AGP 兼容",
            ok,
            f"Kotlin Gradle 插件 {kotlin} / AGP {agp}",
        ))

    # ---- 5) jvmTarget 与 Android 工具链 ----
    if jvm and jvm.isdigit() and int(jvm) < 17:
        checks.append(Check(
            "jvmTarget 不低于 17",
            False,
            f"JvmTarget.JVM_{jvm}；AGP 8.x 要求 17+",
        ))
    else:
        checks.append(Check("jvmTarget 不低于 17", True, f"JVM_{jvm or '?'}"))

    # ---- 6) LiteRT 命名空间与新 native 库 ----
    if litert:
        lm = major_minor(litert)
        checks.append(Check(
            "LiteRT 版本可用",
            lm >= (2, 0),
            f"litert:{litert}（2.x 保留 org.tensorflow.lite.Interpreter，"
            f"并自带 arm64-v8a 的 liblitert_jni.so）",
        ))

    # ---- 7) CameraX 版本 ----
    if camerax:
        checks.append(Check("CameraX 版本已声明", major_minor(camerax) >= (1, 6),
                            f"camera-*:{camerax} 与 Gradle/AGP 组合（1.6.2 为稳定版）"))

    # ---- 8) 模型资产是否声明 ----
    pub = _read(PUBSPEC)
    has_asset = "assets/models/detector.tflite" in pub
    model_on_disk = (REPO_ROOT / "app" / "assets" / "models" / "detector.tflite").exists()
    checks.append(Check(
        "模型已在 pubspec 声明",
        has_asset,
        "已声明 assets/models/detector.tflite" if has_asset
        else "pubspec.yaml 没有声明该资源 -> 模型不会进 APK，真机上只显示「模型未加载」",
    ))
    checks.append(Check(
        "模型文件存在",
        model_on_disk,
        "app/assets/models/detector.tflite 存在" if model_on_disk
        else "文件缺失；跑 scripts/export_tflite.py 生成",
    ))

    # ---- 输出 ----
    errors = [c for c in checks if not c.ok and c.severity == "error"]
    if args.json:
        print(json.dumps(
            {"checks": [{"name": c.name, "ok": c.ok, "detail": c.detail} for c in checks],
             "errors": len(errors),
             "toolchain": {"gradle": gradle, "agp": agp, "kotlin": kotlin,
                           "flutter": flutter, "litert": litert, "camerax": camerax,
                           "flutter_tts": tts}},
            ensure_ascii=False, indent=2))
        return 1 if errors else 0

    print("工具链版本一致性检查")
    print("=" * 62)
    print(f"  Flutter {flutter or '?'} / Gradle {gradle or '?'} / AGP {agp or '?'} / "
          f"Kotlin 插件 {kotlin or '?'}")
    print(f"  LiteRT {litert or '?'} / CameraX {camerax or '?'} / "
          f"flutter_tts {tts or '?'} / jvmTarget {jvm or '?'}")
    print("=" * 62)
    for c in checks:
        mark = "OK  " if c.ok else "FAIL"
        print(f"[{mark}] {c.name}")
        print(f"        {c.detail}")
    print("=" * 62)
    if errors:
        print(f"{len(errors)} 项不一致——先按上面的说明修，不要直接跑构建。")
        return 1
    print("全部一致。可以放心跑构建/导出。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
