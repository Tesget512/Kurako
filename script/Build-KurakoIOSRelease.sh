#!/usr/bin/env bash
set -euo pipefail

# Build the iOS distribution IPA from a no-codesign Flutter Release app.
# Embedded Mach-O files receive identity-free ad-hoc signatures while the
# distributed IPA remains unsigned in the developer-identity sense.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/dist/out"
BUILD_TIME="${KURAKO_BUILD_TIME:-$(date '+%Y-%m-%d %H:%M:%S %z')}"
SKIP_FLUTTER_BUILD="${SKIP_FLUTTER_BUILD:-0}"

export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

cd "$ROOT_DIR"
mkdir -p "$OUT_DIR"

echo "=== Flutter dependencies ==="
flutter pub get

if [[ "$SKIP_FLUTTER_BUILD" == "1" ]]; then
  echo "=== Reusing existing iOS Release build ==="
else
  echo "=== iOS Release build (no developer signing) ==="
  flutter build ios --release --no-codesign \
    "--dart-define=KURAKO_BUILD_TIME=$BUILD_TIME"
fi

APP_SOURCE="$ROOT_DIR/build/ios/iphoneos/Runner.app"
if [[ ! -d "$APP_SOURCE" ]]; then
  echo "找不到 iOS Release Runner.app: $APP_SOURCE" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kurako-ios-release.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

copy_app() {
  local destination="$1"
  mkdir -p "$destination/Payload"
  ditto "$APP_SOURCE" "$destination/Payload/Runner.app"
  find "$destination/Payload/Runner.app" -type d -name _CodeSignature -prune -exec rm -rf {} +
  find "$destination/Payload/Runner.app" -type f -name embedded.mobileprovision -delete
}

is_macho() {
  file -b "$1" 2>/dev/null | grep -q 'Mach-O'
}

sign_macho_files() {
  local app="$1"
  while IFS= read -r -d '' candidate; do
    if is_macho "$candidate"; then
      codesign --force --sign - --preserve-metadata=identifier,entitlements "$candidate"
    fi
  done < <(find "$app" -type f -print0)
}

sign_bundles() {
  local app="$1"
  local bundle
  while IFS= read -r -d '' bundle; do
    codesign --force --sign - --preserve-metadata=identifier,entitlements "$bundle"
  done < <(find "$app/Frameworks" "$app/PlugIns" -type d \( -name '*.framework' -o -name '*.appex' \) -print0 2>/dev/null)
  codesign --force --sign - --preserve-metadata=identifier,entitlements "$app"
}

make_ipa() {
  local app_root="$1"
  local output="$2"
  (cd "$app_root" && zip -qry "$output" Payload)
}

ADHOC_ROOT="$WORK_DIR/adhoc"
copy_app "$ADHOC_ROOT"

echo "=== iOS no_sign IPA ==="
sign_macho_files "$ADHOC_ROOT/Payload/Runner.app"
sign_bundles "$ADHOC_ROOT/Payload/Runner.app"

VERSION="$(sed -n "s/^version: \([0-9][0-9.]*\).*/\1/p" pubspec.yaml | head -1)"
if [[ -z "$VERSION" ]]; then
  echo "无法从 pubspec.yaml 读取版本号" >&2
  exit 1
fi

ADHOC_IPA="$OUT_DIR/Kurako-iOS-${VERSION}-no_sign-release.ipa"
rm -f "$ADHOC_IPA"
make_ipa "$ADHOC_ROOT" "$ADHOC_IPA"

echo "=== Verify IPA signatures ==="
unzip -q "$ADHOC_IPA" -d "$WORK_DIR/adhoc-unzipped"
codesign --verify --deep --strict --verbose=2 "$WORK_DIR/adhoc-unzipped/Payload/Runner.app"
ADHOC_INFO="$(codesign -dvvv "$WORK_DIR/adhoc-unzipped/Payload/Runner.app" 2>&1 || true)"
if ! grep -q '^Signature=adhoc$' <<<"$ADHOC_INFO"; then
  echo "iOS IPA 未检测到预期的 ad-hoc 内层签名" >&2
  exit 1
fi
if grep -q '^Authority=' <<<"$ADHOC_INFO" || \
   grep '^TeamIdentifier=' <<<"$ADHOC_INFO" | grep -vq '^TeamIdentifier=not set$'; then
  echo "iOS IPA 似乎携带开发者身份信息，已停止" >&2
  exit 1
fi
if find "$WORK_DIR/adhoc-unzipped/Payload/Runner.app" -type f -name embedded.mobileprovision -print -quit | grep -q .; then
  echo "iOS IPA 包含 embedded.mobileprovision，已停止" >&2
  exit 1
fi

echo "iOS IPA 已生成："
ls -lh "$ADHOC_IPA"
