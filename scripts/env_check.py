"""验证训练环境可用性。退出码 0 = 可用，1 = 不可用。

用法：
    .venv\\Scripts\\python.exe scripts\\env_check.py
"""
from __future__ import annotations

import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
REPORT_PATH = REPO_ROOT / "runs" / "env_report.json"
MIN_FREE_DISK_GB = 20.0

# RTX 50 系（Blackwell, sm_120）需要 CUDA 12.8+ 的 PyTorch 构建
BLACKWELL_COMPUTE_CAP = (12, 0)


def check_python() -> dict:
    ok = sys.version_info[:2] >= (3, 10) and sys.version_info[:2] < (3, 14)
    detail = platform.python_version()
    if sys.version_info[:2] >= (3, 14):
        detail += "  <- 版本过新，PyTorch 尚无对应 wheel，请使用 3.10-3.13"
    return {"name": "python", "ok": ok, "detail": detail}


def check_packages() -> dict:
    missing: list[str] = []
    versions: dict[str, str] = {}
    for mod in ("torch", "torchvision", "cv2", "ultralytics", "imagehash", "pandas", "yaml"):
        try:
            m = __import__(mod)
            versions[mod] = getattr(m, "__version__", "unknown")
        except ImportError:
            missing.append(mod)
    return {"name": "packages", "ok": not missing, "detail": versions, "missing": missing}


def recommend_batch(vram_gb: float) -> int:
    if vram_gb >= 12:
        return 16
    if vram_gb >= 8:
        return 12
    if vram_gb >= 6:
        return 8
    if vram_gb >= 4:
        return 4
    return 2


def check_cuda() -> dict:
    try:
        import torch
    except ImportError:
        return {"name": "cuda", "ok": False, "detail": "torch 未安装"}
    if not torch.cuda.is_available():
        return {
            "name": "cuda",
            "ok": False,
            "detail": "torch.cuda.is_available() == False；将退化为 CPU 训练",
        }
    idx = torch.cuda.current_device()
    props = torch.cuda.get_device_properties(idx)
    total_gb = props.total_memory / (1024 ** 3)
    cc = (props.major, props.minor)
    detail = {
        "torch": torch.__version__,
        "cuda_runtime": torch.version.cuda,
        "device": props.name,
        "vram_gb": round(total_gb, 2),
        "compute_capability": f"sm_{cc[0]}{cc[1]}",
        "recommended_batch": recommend_batch(total_gb),
    }
    ok = True
    # Blackwell 需要 CUDA 12.8+ 运行时，否则 kernel 不可用
    if cc >= BLACKWELL_COMPUTE_CAP and not _cuda_runtime_supports_blackwell(torch.version.cuda):
        ok = False
        detail["hint"] = (
            f"{props.name} 为 Blackwell 架构（sm_{cc[0]}{cc[1]}），"
            f"但当前 PyTorch 绑定 CUDA {torch.version.cuda}，需 12.8+。"
            "请重装：uv pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128"
        )
    return {"name": "cuda", "ok": ok, "detail": detail}


def _cuda_runtime_supports_blackwell(cuda_version: str | None) -> bool:
    if not cuda_version:
        return False
    try:
        major, minor = (int(x) for x in cuda_version.split(".")[:2])
    except (ValueError, AttributeError):
        return False
    return (major, minor) >= (12, 8)


def check_gpu_compute() -> dict:
    """实际在 GPU 上跑一次张量运算，这是唯一能确证 kernel 可用的方法。"""
    try:
        import torch
    except ImportError:
        return {"name": "gpu_compute", "ok": False, "detail": "torch 未安装"}
    if not torch.cuda.is_available():
        return {"name": "gpu_compute", "ok": False, "detail": "CUDA 不可用，跳过"}
    try:
        x = torch.randn(256, 256, device="cuda")
        y = (x @ x).sum().item()
        return {"name": "gpu_compute", "ok": True, "detail": f"矩阵乘法成功，checksum={y:.2f}"}
    except Exception as exc:  # noqa: BLE001
        return {
            "name": "gpu_compute",
            "ok": False,
            "detail": f"{type(exc).__name__}: {exc}",
            "hint": "若为 'no kernel image is available'，说明 PyTorch 构建不包含该架构的 kernel",
        }


def check_nvidia_smi() -> dict:
    exe = shutil.which("nvidia-smi")
    if exe is None:
        return {"name": "nvidia_smi", "ok": False, "detail": "未找到 nvidia-smi"}
    try:
        out = subprocess.run(
            [exe, "--query-gpu=name,driver_version", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=20, check=False,
        )
        detail = out.stdout.strip() or out.stderr.strip()
        return {"name": "nvidia_smi", "ok": out.returncode == 0, "detail": detail}
    except Exception as exc:  # noqa: BLE001
        return {"name": "nvidia_smi", "ok": False, "detail": repr(exc)}


def check_disk() -> dict:
    try:
        usage = shutil.disk_usage(REPO_ROOT)
        free_gb = usage.free / (1024 ** 3)
    except OSError as exc:
        return {"name": "disk", "ok": False, "detail": f"无法读取磁盘信息：{exc}"}
    return {
        "name": "disk",
        "ok": free_gb >= MIN_FREE_DISK_GB,
        "detail": {"free_gb": round(free_gb, 1), "required_gb": MIN_FREE_DISK_GB},
    }


def check_venv() -> dict:
    in_venv = sys.prefix != getattr(sys, "base_prefix", sys.prefix)
    return {
        "name": "venv",
        "ok": in_venv,
        "detail": sys.prefix if in_venv else "未在虚拟环境中运行，请使用 .venv\\Scripts\\python.exe",
    }


def main() -> int:
    checks = [
        check_python(),
        check_venv(),
        check_packages(),
        check_cuda(),
        check_gpu_compute(),
        check_nvidia_smi(),
        check_disk(),
    ]
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(
        json.dumps({"checks": checks}, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    for c in checks:
        print(f"[{'OK  ' if c['ok'] else 'FAIL'}] {c['name']}: {c['detail']}")
        if not c["ok"] and c.get("hint"):
            print(f"        提示：{c['hint']}")
    print(f"\nreport -> {REPORT_PATH}")

    critical = {"python", "venv", "packages", "cuda", "gpu_compute"}
    failed_critical = [c["name"] for c in checks if not c["ok"] and c["name"] in critical]
    if failed_critical:
        print(f"\n关键项未通过：{failed_critical}。请修复后再进入训练。")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
