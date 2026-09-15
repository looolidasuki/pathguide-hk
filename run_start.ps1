# run_start.ps1
#项目根目录
$PSScriptRoot
#激活python虚拟环境
.\.venv\Scripts\Activate.ps1
#点源加载环境变量 .env.ps1
. .\.env.ps1
#启动你的python脚本
python scripts\report_training.py
