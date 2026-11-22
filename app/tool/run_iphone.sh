#!/bin/sh
set -eu
app_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ ! -f "$app_dir/config/firebase.local.json" ]; then
  echo '請先執行 python3 tool/configure_firebase_ios.py /完整路徑/GoogleService-Info.plist' >&2
  exit 1
fi
cd "$app_dir"
if [ "${1:-}" = '--build-scene-trial' ]; then
  shift
  if [ ! -f "$app_dir/config/appcheck-trial.local.json" ]; then
    echo '缺少私人場景測試的 App Check 設定 config/appcheck-trial.local.json。' >&2
    exit 1
  fi
  exec flutter build ios --profile "$@" \
    --dart-define-from-file="$app_dir/config/firebase.local.json" \
    --dart-define-from-file="$app_dir/config/appcheck-trial.local.json" \
    --dart-define-from-file="$app_dir/config/scene.ios-trial.json"
fi
exec flutter run --release --dart-define-from-file="$app_dir/config/firebase.local.json" "$@"
