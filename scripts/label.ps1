# 启动 X-AnyLabeling 标注图像目录。
#
# 为什么要一个脚本：直接敲 anylabeling 的路径有两个坑，都很难自查——
#   1. PowerShell 里 `.venv-label\Scripts\anylabeling.exe` 开头是 `.`，
#      会被当成模块名解析，报 “The module '.venv-label' could not be loaded”；
#   2. 当前工作目录不对时，`.anylabelingrc` 找不到，于是加载的是默认 80 类
#      （COCO）标签表——而画出来的框类名全是错的，也不报错。
# 这个脚本把两件事都固定住：用绝对路径调用，并显式 --config 指向仓库里那份 48 类表。
#
# 用法：
#   .\scripts\label.ps1                                  # 默认打开待标注帧目录
#   .\scripts\label.ps1 -Images data\frames\selected\myVideo
#   .\scripts\label.ps1 -Images <目录> -DryRun            # 只打印要执行的命令

[CmdletBinding()]
param(
    [string]$Images = "data\frames\label_me\myVideo",
    [string]$Config = ".anylabelingrc",
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"

# 仓库根 = 本脚本的上一级目录，这样在任何工作目录下执行都对
$repo = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $repo ".venv-label\Scripts\anylabeling.exe"
$cfg = if ([System.IO.Path]::IsPathRooted($Config)) { $Config }
       else { Join-Path $repo $Config }
$imgs = if ([System.IO.Path]::IsPathRooted($Images)) { $Images }
        else { Join-Path $repo $Images }

if (-not (Test-Path $exe)) {
    Write-Host "找不到标注程序：$exe" -ForegroundColor Red
    Write-Host "（这个环境是 uv 建的，没有 pip；用 uv 装依赖）" -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path $cfg)) {
    Write-Host "找不到类别表配置：$cfg" -ForegroundColor Red
    Write-Host "先生成：python scripts\make_anylabeling_config.py --out .anylabelingrc --labels-file configs\classes.txt" -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path $imgs)) {
    Write-Host "找不到图像目录：$imgs" -ForegroundColor Red
    Write-Host "可先倒帧：python scripts\extract_frames.py --videos data\raw\myVideo --fps 0.1 --out data\frames\label_me --dedup-threshold 6" -ForegroundColor Yellow
    exit 1
}

$n = (Get-ChildItem $imgs -File -Include *.jpg, *.jpeg, *.png -Recurse -ErrorAction SilentlyContinue).Count
$classes = (Select-String -Path $cfg -Pattern "^-\s+(\w+)$" -ErrorAction SilentlyContinue).Count

Write-Host "标注程序：$exe"
Write-Host "类别表  ：$cfg  （$classes 类）"
Write-Host "图像目录：$imgs  （$n 张）"
if ($classes -lt 40) {
    Write-Host "警告：类别表里只有 $classes 类，可能不是当前的 48 类表。" -ForegroundColor Yellow
}
if ($n -eq 0) {
    Write-Host "警告：该目录下没有图像。" -ForegroundColor Yellow
}

# ---- 守卫：家目录里那份旧配置 ----
#
# X-AnyLabeling 会在退出时把**当前配置写回** ~/.anylabelingrc。如果那里残留着
# 上一版类别表（实测有一份 24 类的，含已删掉的 cart_trolley / ambiguous_vertical），
# 那么**不带 --config 启动**时就会加载它：少 24 个新类，而且索引 23 的含义不同
# （旧 ambiguous_vertical vs 新 fork_in_road）。
# 后果是画出来的框在数据集里指向另一个类，**训练不报错**——所以这里要吼一声。
$userRc = Join-Path $env:USERPROFILE ".anylabelingrc"
if (Test-Path $userRc) {
    $userLabels = @(Select-String -Path $userRc -Pattern "^-\s+(\w+)$" -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.Matches[0].Groups[1].Value })
    $want = @(Select-String -Path $cfg -Pattern "^-\s+(\w+)$" -ErrorAction SilentlyContinue |
              ForEach-Object { $_.Matches[0].Groups[1].Value })
    if ($userLabels.Count -ne $want.Count -or (Compare-Object $userLabels $want)) {
        Write-Host ""
        Write-Host "注意：$userRc 里是另一份类别表（$($userLabels.Count) 类，本表 $($want.Count) 类）。" -ForegroundColor Yellow
        Write-Host "      本次因为显式传了 --config，用的是本表，不受影响；" -ForegroundColor Yellow
        Write-Host "      但**不要**直接双击或裸敲 anylabeling 启动，否则会加载旧表、类名错位且不报错。" -ForegroundColor Yellow
        Write-Host "      正常退出一次后该文件会被本次配置覆盖。" -ForegroundColor DarkGray
    }
}

if ($DryRun) {
    Write-Host "`n[DryRun] 将要执行：" -ForegroundColor Cyan
    Write-Host "  `"$exe`" --config `"$cfg`" `"$imgs`""
    exit 0
}

Write-Host "`n启动中（关掉窗口即退出）…" -ForegroundColor Green
# 用绝对路径 + 调用运算符，避免开头 `.` 被 PowerShell 当成模块名
& $exe --config $cfg $imgs
exit $LASTEXITCODE
