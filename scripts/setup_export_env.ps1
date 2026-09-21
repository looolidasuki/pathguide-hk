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
#
# ★ protobuf 与 tf_keras 必须**显式钉死**，否则必然出问题：
#   - onnx2tf 会把 protobuf 拉到 7.x，而 TensorFlow 2.19 只认 protobuf 4/5。
#     症状是 `import tensorflow` 报
#         AttributeError: 'MessageFactory' object has no attribute 'GetPrototype'
#     这不是 TensorFlow 的错，是 protobuf 版本不匹配。
#   - tf_keras 也要 2.19（与 TF 同版本），装到 2.15 会报
#         module 'tensorflow._api.v2.compat.v2.__internal__' has no attribute
#         'register_load_context_function'
#
# ★ ultralytics 必须钉 8.3.x，**不能用最新的 8.4.x**：
#   8.4.83 起把 `format='tflite'` 重定向到新的 'litert' 导出器，而那个
#   只在 Linux x86 与 macOS 上可用，Windows 上直接断言失败：
#         assert MACOS or (LINUX and not ARM64),
#         "LiteRT export only supported on Linux x86 and macOS"
#   8.3.x 走的是 ONNX -> TensorFlow SavedModel -> TFLite 老链路，Windows 可用。
#   钉 8.3.253 还顺带保证与训练出该权重的版本一致。
Write-Host "`n安装核心依赖（仅 PyPI，钉死 protobuf / tf_keras / ultralytics）..." -ForegroundColor Yellow
uv pip install --python $py `
    "tensorflow==2.19.0" `
    "tf_keras==2.19.0" `
    "protobuf>=4.25.3,<6" `
    "ai-edge-litert" `
    "onnx2tf" `
    "sng4onnx" `
    "onnx_graphsurgeon" `
    "onnx" `
    "onnxruntime" `
    "onnxslim" `
    "ultralytics==8.3.253" `
    "numpy<2.1"

# 为什么 ai-edge-litert 必须显式列出：
#   onnx2tf 1.28.8 的 utils/common_functions.py 第 20 行是**无条件** import：
#       from ai_edge_litert.interpreter import Interpreter
#   没有 try/except 兜底，缺了就 ModuleNotFoundError。虽然 TensorFlow 2.19 自带
#   等价的 tensorflow.lite.Interpreter，但 onnx2tf 不认。
#   它的依赖是松散的（protobuf 无版本约束），因此**必须与 protobuf 一起装**，
#   并且靠上面的 <6 约束阻止它把 protobuf 抬到 7——那正是让 TF 2.19 失效的原因。

Write-Host "`n验证导入..." -ForegroundColor Yellow
# 把校验代码写成临时文件再执行。
# **不要用 `python -c <多行字符串>`**：Windows 命令行对多行参数与内嵌引号的
# 传递不可靠，实测会被截断成 `SyntaxError: '(' was never closed`。
$verifyPath = Join-Path ([System.IO.Path]::GetTempPath()) "dsh_verify_export_env.py"
$verifyLines = @(
    'import sys',
    'ok = True',
    'for name in ["tensorflow", "tf_keras", "onnx", "onnx2tf", "ultralytics"]:',
    '    try:',
    '        m = __import__(name)',
    '        print("  OK   %-14s %s" % (name, getattr(m, "__version__", "?")))',
    '    except Exception as e:',
    '        ok = False',
    '        print("  FAIL %-14s %s: %s" % (name, type(e).__name__, e))',
    'import importlib.metadata as md',
    'for pkg in ["protobuf", "tensorflow", "tf_keras", "onnx2tf"]:',
    '    try:',
    '        print("  %-14s %s" % (pkg, md.version(pkg)))',
    '    except Exception:',
    '        pass',
    '# protobuf 主版本必须 < 6，否则 TensorFlow 2.19 的 C++ 侧认不出来。',
    'try:',
    '    major = int(md.version("protobuf").split(".")[0])',
    '    if major >= 6:',
    '        ok = False',
    '        print("  FAIL protobuf 主版本 %d >= 6，TensorFlow 2.19 无法使用" % major)',
    'except Exception:',
    '    pass',
    'sys.exit(0 if ok else 1)'
)
Set-Content -Path $verifyPath -Value $verifyLines -Encoding UTF8
& $py $verifyPath
$verifyExit = $LASTEXITCODE
Remove-Item $verifyPath -Force -ErrorAction SilentlyContinue

if ($verifyExit -ne 0) {
    Write-Host "`n有依赖导入失败，导出无法进行。把上面的 FAIL 行贴回来。" -ForegroundColor Red
    return
}

Write-Host "`n导出环境就绪。用法：" -ForegroundColor Green
Write-Host "  .\.venv-export\Scripts\python.exe scripts\export_tflite.py"
Write-Host ""
Write-Host "注意：**不要**在主 .venv 里跑导出——那会把 protobuf 搅乱，" -ForegroundColor DarkGray
Write-Host "      连带让训练环境里的 tensorflow 无法导入。" -ForegroundColor DarkGray
