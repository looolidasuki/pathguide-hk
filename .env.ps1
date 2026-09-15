# 用法：在本目录执行  . .\.env.ps1
#
# 作用：
#   1. 激活虚拟环境
#   2. 把各类缓存重定向到工作区内（默认位置在 %LOCALAPPDATA% / %APPDATA%，
#      会被文件沙箱拒绝写入）
#   3. 若存在 .env.secret.ps1 则加载其中的密钥（该文件不入库）
#
# 本文件**可以安全提交**——它不含任何密钥。

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

# ---- 缓存重定向（受限环境必需）----
$env:UV_CACHE_DIR = Join-Path $repoRoot ".uv-cache"
$env:YOLO_CONFIG_DIR = Join-Path $repoRoot ".ultralytics-config"
$env:MPLCONFIGDIR = Join-Path $repoRoot ".mpl-cache"
New-Item -ItemType Directory -Force -Path $env:YOLO_CONFIG_DIR, $env:MPLCONFIGDIR | Out-Null

# ---- 密钥（可选）----
# .env.secret.ps1 被 .gitignore 排除。缺失时不影响训练与探测，只影响需联网的 API。
$secretFile = Join-Path $repoRoot ".env.secret.ps1"
$secretLoaded = $false
if (Test-Path $secretFile) {
    . $secretFile
    $secretLoaded = $true
}

Write-Host "虚拟环境已激活" -ForegroundColor Green
Write-Host "  repo            : $repoRoot"
Write-Host "  UV_CACHE_DIR    : $env:UV_CACHE_DIR"
Write-Host "  YOLO_CONFIG_DIR : $env:YOLO_CONFIG_DIR"
if ($secretLoaded) {
    $names = @()
    foreach ($k in @('ROBOFLOW_API_KEY')) {
        if ((Get-Item "env:$k" -ErrorAction SilentlyContinue)) {
            $names += "$k(len=$((Get-Item "env:$k").Value.Length))"
        }
    }
    Write-Host "  密钥            : 已加载 $($names -join ', ')" -ForegroundColor Green
} else {
    Write-Host "  密钥            : 未找到 .env.secret.ps1（训练/探测不受影响）" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "常用命令：" -ForegroundColor Cyan
Write-Host "  python scripts\env_check.py                 # 环境自检"
Write-Host "  python -m pytest tests\ -v                  # 单元测试"
Write-Host "  python scripts\run_pipeline.py --epochs 40  # 端到端跑通训练流程"
Write-Host "  python scripts\probe\probe_zeroshot.py      # 零样本可辨识性探测"
