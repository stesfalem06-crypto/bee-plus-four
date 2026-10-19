#!/usr/bin/env bash
# 4 release build with encrypted study content (1.0.4+). Usage:
#   tool/build_release.sh [extra flutter build args]       e.g. --split-per-abi --target-platform android-arm
# Needs the content key file (default /workspace/keys/four/content_key.bin, or $FOUR_CONTENT_KEY_FILE) and the
# signing setup in android/key.properties. Symbols go to $FOUR_SYMBOLS (default build/symbols) — keep them private.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tool/encrypt_assets.py
python3 tool/encrypt_assets.py --verify
flutter build apk --release --obfuscate --split-debug-info="${FOUR_SYMBOLS:-build/symbols}" \
  --dart-define-from-file=.four_content_define.json "$@"
