<#
骨干对比扫描：同一数据集、同一超参，只换骨干。

## 为什么单独写成脚本

比较骨干必须控制变量。手工一个个敲命令，很容易在某一版上漏掉参数、
或改了顺序忘了改回来——而那种差异最后会被误读成「骨干更好/更差」。
所以把「固定什么、变化什么」写死在脚本里，并打印出来。

## 固定项
  data / imgsz / batch / epochs / seed / workers / lr0(默认) / 数据增强(ultralytics 默认)

## 变化项
  仅 --model（起点权重）

## 代价
实测 workers=8 时 60.6 秒/轮（workers=0 是 152.7），60 轮约 1 小时一个骨干。
四个骨干约 4 小时。所以用后台任务跑。

用法：
  powershell -ExecutionPolicy Bypass -File scripts\sweep_backbones.ps1
  powershell -ExecutionPolicy Bypass -File scripts\sweep_backbones.ps1 -Backbones yolo26n.pt
#>
param(
  [string[]]$Backbones = @("yolov8n.pt", "yolo11n.pt", "yolo12n.pt", "yolo26n.pt"),
  [string]$Data = "data\dataset_poc5\dataset.yaml",
  [int]$Epochs = 60,
  [int]$Workers = 8,
  [switch]$SkipTrain
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# 与 .env.flutter.ps1 独立：训练只需要 ultralytics 的配置目录重定向
$env:YOLO_CONFIG_DIR = Join-Path $root ".tools\ultralytics"
$env:UV_CACHE_DIR   = Join-Path $root ".uv-cache"
$env:APPDATA        = Join-Path $root ".tools\appdata"
$env:TMP            = Join-Path $root ".tools\tmp"
$env:TEMP           = $env:TMP

$py = Join-Path $root ".venv\Scripts\python.exe"

Write-Host "===== 骨干对比扫描 =====" -ForegroundColor Cyan
Write-Host "固定项："
Write-Host "  data    $Data"
Write-Host "  epochs  $Epochs"
Write-Host "  workers $Workers"
Write-Host "  imgsz   416 / batch 16 / seed 42（train_yolo.py 的默认，未改动）"
Write-Host "变化项：仅起点权重"
foreach ($b in $Backbones) { Write-Host "  - $b" }
Write-Host ""

$names = @()
$failed = @()
foreach ($b in $Backbones) {
  if (-not (Test-Path (Join-Path $root $b))) {
    Write-Host "权重不存在，跳过：$b" -ForegroundColor Yellow
    $failed += "$b（权重文件不存在）"
    continue
  }
  $tag = ($b -replace "\.pt$", "") -replace "[^A-Za-z0-9]", ""
  $name = "pg_b_$tag"
  $names += $name
  if ($SkipTrain) { continue }

  Write-Host "----- 训练 $b  ->  runs\$name -----" -ForegroundColor Green
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  & $py "scripts\train_yolo.py" --data $Data --name $name --model $b `
        --epochs $Epochs --workers $Workers 2>&1 |
    Select-String -Pattern "起点权重|验证结果|mAP50|mAP50-95|precision|recall|Traceback|Error|TypeError" |
    ForEach-Object { $_.Line }
  $sw.Stop()
  Write-Host ("  用时 {0:N1} 分钟" -f $sw.Elapsed.TotalMinutes)

  # ★ 必须显式检查训练是否真的产出了权重。
  # 踩过：yolo26n 因 SPPF 签名不兼容而训练失败（ultralytics 8.3.253 太旧），
  # 后续对比按 Test-Path 过滤权重时**把它静默丢掉了** —— 结果表里只有 3 个模型，
  # 读的人会以为只测了 3 个骨干。而「少一个模型却看不出少了」正是本项目
  # 反复出现的失败模式。
  if (-not (Test-Path (Join-Path $root "runs\$name\weights\best.pt"))) {
    Write-Host "  ❌ 训练未产出 best.pt：$b" -ForegroundColor Red
    $failed += $b
  }
}

if ($failed.Count -gt 0) {
  Write-Host "`n$('=' * 60)" -ForegroundColor Red
  Write-Host "以下骨干**没有进入对比**（不是「没测」，是「没训成」）：" -ForegroundColor Red
  foreach ($f in $failed) { Write-Host "  - $f" -ForegroundColor Red }
  Write-Host "对比表里不会出现它们，请勿据此认为它们已经被评估过。" -ForegroundColor Red
  Write-Host "$('=' * 60)`n" -ForegroundColor Red
}

if ($names.Count -lt 2) {
  Write-Host "能比的模型少于 2 个，结束。" -ForegroundColor Yellow
  exit 1
}

# ---- 在同一份验证集上按阈值对比 ----
$weights = @()
foreach ($n in $names) {
  $w = "runs\$n\weights\best.pt"
  if (Test-Path (Join-Path $root $w)) { $weights += $w }
  else { Write-Host "跳过（无权重）：$w" -ForegroundColor Yellow }
}

Write-Host "`n===== 同一验证集上的对比（$Data 的 val）=====" -ForegroundColor Cyan
Write-Host ("参与对比的模型（{0} 个）：{1}" -f $weights.Count, ($weights -join ", "))
& $py "scripts\compare_at_threshold.py" --data $Data --weights @weights `
      --grid "0.30,0.40,0.50,0.55,0.60,0.65,0.70,0.80" `
      --out "artifacts\metrics\backbone_sweep.json"

Write-Host "`n完成。结果 JSON：artifacts\metrics\backbone_sweep.json" -ForegroundColor Green
Write-Host "提醒：多数情况应按同等精确率比较，用" -NoNewline
Write-Host " python scripts\matched_precision.py --json artifacts\metrics\backbone_sweep.json" -ForegroundColor Cyan
