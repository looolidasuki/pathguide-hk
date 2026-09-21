# 建一个**专用**的 TFLite 导出环境。用法：
#   . .\scripts\setup_export_env.ps1
#
# ## 为什么必须独立环境
#
# 导出链是 PyTorch -> ONNX -> TensorFlow SavedModel -> TFLite，其中 onnx2tf 需要
# tf_keras<=2.19.0 + TensorFlow 2.19 + 与之匹配的 protobuf。这套依赖与训练环境
# （ultralytics + torch + numpy 2.x）冲突：实测装进同一个 venv 后，`import tensorflow`
# 直接失败：
#
#     AttributeError: 'MessageFactory' object has no attribute 'GetPrototype'
#
# 那是 protobuf 被搅乱的症状，会连带把 tf_keras 的导入也炸掉。
# 所以导出**必须在 .venv-export 里**跑，主 .venv 保持干净。
# 与本仓库已有的 .venv-vlm / .venv-label 是同一个思路。

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$venv = Join-Path $repoRoot ".venv-export"

# uv 缓存重定向到工作区内（默认在 %LOCALAPPDATA%，受限环境会被拒写）
$env:UV_CACHE_DIR = Join-Path $repoRoot ".uv-cache"

Write-Host "仓库根目录：$repoRoot" -ForegroundColor Cyan

if (-not (Test-Path (Join-Path $venv "Scripts\python.exe"))) {
    Write-Host "创建 $venv ..." -ForegroundColor Yellow
    uv venv --python 3.12 $venv
} else {
    Write-Host "复用已存在的 $venv" -ForegroundColor DarkGray
}

$py = Join-Path $venv "Scripts\python.exe"

# 先装 pi 上没有冲突的核心依赖。刻意**只用默认 PyPI 索引**：
# ultralytics 的自动安装会加 --extra-index-url https://pypi.ngc.nvidia.com，
# 那个域名在部分网络下 DNS 解析失败（实测 os error 11001），导致整批安装失败。
Write-Host "`n安装核心依赖（仅 PyPI）..." -ForegroundColor Yellow
uv pip install --python $py `
    "tensorflow==2.19.0" `
    "tf_keras<=2.19.0" `
    "onnx2tf" `
    "sng4onnx" `
    "onnx_graphsurgeon" `
    "onnx" `
    "onnxruntime" `
    "onnxslim" `
    "ultralytics" `
    "numpy<2.1"

Write-Host "`n验证导入..." -ForegroundColor Yellow
# 用**单引号** here-string：不做变量展开，因此 Python 里的引号和 $ 都不需要转义。
$verify = @'
import sys
ok = True
for name in ["tensorflow", "tf_keras", "onnx", "onnx2tf", "ultralytics"]:
    try:
        m = __import__(name)
        print("  OK   %-14s %s" % (name, getattr(m, "__version__", "?")))
    except Exception as e:
        ok = False
        print("  FAIL %-14s %s: %s" % (name, type(e).__name__, e))
import importlib.metadata as md
try:
    print("  protobuf       %s" % md.version("protobuf"))
except Exception:
    pass
sys.exit(0 if ok else 1)
'@
& $py -c $verify

if ($LASTEXITCODE -ne 0) {
    Write-Host "`n有依赖导入失败，导出无法进行。把上面的 FAIL 行贴回来。" -ForegroundColor Red
    return
}

Write-Host "`n导出环境就绪。用法：" -ForegroundColor Green
Write-Host "  .\.venv-export\Scripts\python.exe scripts\export_tflite.py"
Write-Host ""
Write-Host "注意：**不要**在主 .venv 里跑导出——那会把 protobuf 搅乱，" -ForegroundColor DarkGray
Write-Host "      连带让训练环境里的 tensorflow 无法导入。" -ForegroundColor DarkGray
