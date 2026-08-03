#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/dist/out"
BUILD_TIME="${KURAKO_BUILD_TIME:-$(date '+%Y-%m-%d %H:%M:%S %z')}"
FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter || true)}"

export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script must run on Linux; Flutter Linux bundles cannot be built on $(uname -s)." >&2
  exit 1
fi
if [[ -z "$FLUTTER_BIN" || ! -x "$FLUTTER_BIN" ]]; then
  echo "Flutter not found. Add flutter to PATH or set FLUTTER_BIN." >&2
  exit 1
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "Experimental Linux builds currently support x86_64 DEB only; found $(uname -m)." >&2
  exit 1
fi
FLUTTER_ARCH="x64"
DIST_ARCH="x86_64"

VERSION="$(awk '/^version:/ {print $2; exit}' "$ROOT_DIR/pubspec.yaml")"
VERSION="${VERSION%%+*}"
if [[ -z "$VERSION" ]]; then
  echo "Unable to read version from pubspec.yaml." >&2
  exit 1
fi

BUNDLE_DIR="$ROOT_DIR/build/linux/$FLUTTER_ARCH/release/bundle"

cd "$ROOT_DIR"
"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" build linux --release --no-pub \
  "--dart-define=KURAKO_BUILD_TIME=$BUILD_TIME"

if [[ ! -x "$BUNDLE_DIR/kurako" || ! -d "$BUNDLE_DIR/lib" || ! -d "$BUNDLE_DIR/data" ]]; then
  echo "Incomplete Flutter Linux bundle: $BUNDLE_DIR" >&2
  exit 1
fi

ACTUAL_ARCH="$(file -b "$BUNDLE_DIR/kurako")"
case "$DIST_ARCH:$ACTUAL_ARCH" in
  x86_64:*x86-64*|arm64:*aarch64*) ;;
  *) echo "Unexpected executable architecture: $ACTUAL_ARCH" >&2; exit 1 ;;
esac

mapfile -d '' ELF_FILES < <(
  find "$BUNDLE_DIR" -type f -print0 | while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -q '^ELF '; then
      printf '%s\0' "$candidate"
    fi
  done
)
for elf_file in "${ELF_FILES[@]}"; do
  if ldd "$elf_file" 2>/dev/null | grep -q "not found"; then
    echo "Unresolved shared libraries in $elf_file:" >&2
    ldd "$elf_file" >&2 || true
    exit 1
  fi
done

printf 'Experimental Linux Release bundle ready for DEB packaging:\n  %s\n  build time: %s\n  architecture: %s\n' \
  "$BUNDLE_DIR" "$BUILD_TIME" "$DIST_ARCH"
