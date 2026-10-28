#!/bin/sh
set -eu
app_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ ! -f "$app_dir/config/firebase.local.json" ]; then
  echo '請先執行 python3 tool/configure_firebase_ios.py /完整路徑/GoogleService-Info.plist' >&2
  exit 1
fi
cd "$app_dir"
exec flutter run --release --dart-define-from-file="$app_dir/config/firebase.local.json" "$@"
