# 修复主 .venv：把被搅乱的 TensorFlow 依赖降回兼容版本。
#
# ## 为什么需要它
#
# TFLite 导出链（onnx2tf）会把 protobuf 升到 7.x，而 TensorFlow 2.19 只认 protobuf 4/5。
# 一旦在**主 .venv** 里装了导出依赖，`import tensorflow` 就会失败：
#
#     AttributeError: 'MessageFactory' object has no attribute 'GetPrototype'
#
# 后续可能连带把 tf_keras 的导入也炸掉。
#
# 正解是导出用独立的 .venv-export（见 scripts/setup_export_env.ps1）。
# 本脚本只是把主环境修回可用状态——**训练本身不依赖 TensorFlow**，
# 所以主环境即使 tensorflow 坏着也能训练；这里修它是为了干净。

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$venv = Join-Path $repoRoot ".venv"
$py = Join-Path $venv "Scripts\python.exe"

if (-not (Test-Path $py)) {
    Write-Host "未找到主虚拟环境：$py" -ForegroundColor Red
    return
}
$env:UV_CACHE_DIR = Join-Path $repoRoot ".uv-cache"

Write-Host "修复前状态：" -ForegroundColor Cyan
& $py -c @'
import importlib.metadata as md
for p in ["protobuf", "tf_keras", "tensorflow", "numpy", "ultralytics", "torch"]:
    try:
        print("  %-14s %s" % (p, md.version(p)))
    except Exception:
        print("  %-14s <未安装>" % p)
'@

Write-Host "`n把 protobuf 与 tf_keras 降回与 TensorFlow 2.19 兼容的版本..." -ForegroundColor Yellow
uv pip install --python $py "protobuf>=4.25.3,<6" "tf_keras==2.19.0"

Write-Host "`n修复后验证：" -ForegroundColor Cyan
& $py -c "import tensorflow, tf_keras, ultralytics, torch; print('  全部导入 OK'); print('  tensorflow', tensorflow.__version__); print('  ultralytics', ultralytics.__version__); print('  torch', torch.__version__)"

if ($LASTEXITCODE -ne 0) {
    Write-Host "`n仍有导入失败。若只影响 tensorflow，训练不受影响——" -ForegroundColor Yellow
    Write-Host "导出请一律用 .venv-export，不要在这里做。" -ForegroundColor Yellow
    return
}

Write-Host "`n主环境已修复。" -ForegroundColor Green
Write-Host "提醒：不要在 .venv 里跑 TFLite 导出，那会重新把 protobuf 升上去。" -ForegroundColor DarkGray
