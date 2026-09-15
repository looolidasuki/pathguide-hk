# 用法：在本目录执行  . .\.env.ps1
# 作用：激活虚拟环境，并把 uv 缓存重定向到工作区内
#       （默认缓存在 %LOCALAPPDATA%\uv\cache，会被文件沙箱拒绝写入）

$ErrorActionPreference = "Stop"

$repoRoot = $PSScriptRoot
$venvActivate = Join-Path $repoRoot ".venv\Scripts\Activate.ps1"

if (-not (Test-Path $venvActivate)) {
    Write-Host "未找到虚拟环境：$venvActivate" -ForegroundColor Red
    Write-Host "请先执行：" -ForegroundColor Yellow
    Write-Host "  uv venv --python 3.12 .venv" -ForegroundColor Yellow
    return
}

. $venvActivate

# uv 缓存重定向到工作区内
$env:UV_CACHE_DIR = Join-Path $repoRoot ".uv-cache"

# Ultralytics 设置与 matplotlib 缓存同样重定向（默认在 %APPDATA%，会被沙箱拒绝）
$env:YOLO_CONFIG_DIR = Join-Path $repoRoot ".ultralytics-config"
$env:MPLCONFIGDIR = Join-Path $repoRoot ".mpl-cache"
New-Item -ItemType Directory -Force -Path $env:YOLO_CONFIG_DIR, $env:MPLCONFIGDIR | Out-Null

Write-Host "虚拟环境已激活" -ForegroundColor Green
Write-Host "  python          : $(Get-Command python).Source"
Write-Host "  UV_CACHE_DIR    : $env:UV_CACHE_DIR"
Write-Host "  YOLO_CONFIG_DIR : $env:YOLO_CONFIG_DIR"
Write-Host ""
Write-Host "常用命令：" -ForegroundColor Cyan
Write-Host "  python scripts\env_check.py                 # 环境自检"
Write-Host "  python -m pytest tests\ -v                  # 单元测试"
Write-Host "  python scripts\run_pipeline.py --epochs 40  # 端到端跑通训练流程"
