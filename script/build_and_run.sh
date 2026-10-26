#!/usr/bin/env bash
set -euo pipefail

# Reproducible macOS test loop. The software-rendering argument is intentional:
# this machine has no Metal-capable GPU, so the normal Flutter macOS renderer
# cannot be used as a useful visual test here.
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter || true)}"
APP_NAME="kurako"
APP_BUNDLE="$ROOT_DIR/build/macos/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [[ -z "$FLUTTER_BIN" || ! -x "$FLUTTER_BIN" ]]; then
  echo "Flutter not found. Add flutter to PATH or set FLUTTER_BIN." >&2
  exit 1
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
BUILD_TIME="$(date '+%Y-%m-%d %H:%M:%S %z')"
"$FLUTTER_BIN" build macos --debug --no-pub "--dart-define=KURAKO_BUILD_TIME=$BUILD_TIME"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE" --args --enable-software-rendering --enable-impeller=false
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY" --enable-software-rendering --enable-impeller=false
    ;;
  --logs|logs|--telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
