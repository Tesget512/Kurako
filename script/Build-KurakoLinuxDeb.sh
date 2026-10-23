#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/dist/out"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script must run on Linux; Debian packages cannot be built on $(uname -s)." >&2
  exit 1
fi

for command_name in dpkg dpkg-deb dpkg-shlibdeps file patchelf desktop-file-validate appstreamcli; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
done

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "Experimental Linux packages currently support x86_64 DEB only; found $(uname -m)." >&2
  exit 1
fi
FLUTTER_ARCH="x64"
DIST_ARCH="x86_64"
DEB_ARCH="amd64"

VERSION="$(awk '/^version:/ {print $2; exit}' "$ROOT_DIR/pubspec.yaml")"
if [[ -z "$VERSION" ]]; then
  echo "Unable to read version from pubspec.yaml." >&2
  exit 1
fi

BUNDLE_DIR="${KURAKO_LINUX_BUNDLE_DIR:-$ROOT_DIR/build/linux/$FLUTTER_ARCH/release/bundle}"
PACKAGING_DIR="$ROOT_DIR/linux/packaging"
WORK_DIR="$ROOT_DIR/build/linux/$FLUTTER_ARCH/debian"
PACKAGE_ROOT="$WORK_DIR/kurako"
DEBIAN_DIR="$PACKAGE_ROOT/DEBIAN"
DEPENDENCY_LOG="$WORK_DIR/dpkg-shlibdeps.log"
PACKAGE_NAME="Kurako-Linux-$VERSION-$DIST_ARCH.deb"
PACKAGE_PATH="$OUT_DIR/$PACKAGE_NAME"

if [[ ! -x "$BUNDLE_DIR/kurako" || ! -d "$BUNDLE_DIR/lib" || ! -d "$BUNDLE_DIR/data" ]]; then
  echo "Incomplete Flutter Linux bundle: $BUNDLE_DIR" >&2
  echo "Run script/Build-KurakoLinuxRelease.sh first or set KURAKO_LINUX_BUNDLE_DIR." >&2
  exit 1
fi
for metadata_file in \
  "$PACKAGING_DIR/com.tesget.kurako.desktop" \
  "$PACKAGING_DIR/com.tesget.kurako.metainfo.xml" \
  "$PACKAGING_DIR/com.tesget.kurako.png"; do
  if [[ ! -f "$metadata_file" ]]; then
    echo "Missing Linux packaging metadata: $metadata_file" >&2
    exit 1
  fi
done

ACTUAL_ARCH="$(file -b "$BUNDLE_DIR/kurako")"
case "$DIST_ARCH:$ACTUAL_ARCH" in
  x86_64:*x86-64*|arm64:*aarch64*) ;;
  *)
    echo "Unexpected executable architecture: $ACTUAL_ARCH" >&2
    exit 1
    ;;
esac

desktop-file-validate "$PACKAGING_DIR/com.tesget.kurako.desktop"
appstreamcli validate --no-net "$PACKAGING_DIR/com.tesget.kurako.metainfo.xml"

rm -rf "$WORK_DIR"
mkdir -p \
  "$DEBIAN_DIR" \
  "$WORK_DIR/debian" \
  "$PACKAGE_ROOT/opt/kurako" \
  "$PACKAGE_ROOT/usr/bin" \
  "$PACKAGE_ROOT/usr/share/applications" \
  "$PACKAGE_ROOT/usr/share/metainfo" \
  "$PACKAGE_ROOT/usr/share/icons/hicolor/512x512/apps" \
  "$PACKAGE_ROOT/usr/share/doc/kurako"

cp -a "$BUNDLE_DIR/." "$PACKAGE_ROOT/opt/kurako/"
cat > "$PACKAGE_ROOT/usr/bin/kurako" <<'LAUNCHER'
#!/bin/sh

case "${KURAKO_SOFTWARE_RENDERING:-auto}" in
  1|true|yes)
    export LIBGL_ALWAYS_SOFTWARE=1
    ;;
  0|false|no)
    ;;
  auto|"")
    if [ -r /sys/class/dmi/id/product_name ] && \
      grep -qi 'VirtualBox' /sys/class/dmi/id/product_name; then
      export LIBGL_ALWAYS_SOFTWARE=1
    fi
    ;;
esac

exec /opt/kurako/kurako "$@"
LAUNCHER
chmod 0755 "$PACKAGE_ROOT/usr/bin/kurako"
install -m 0644 "$PACKAGING_DIR/com.tesget.kurako.desktop" \
  "$PACKAGE_ROOT/usr/share/applications/com.tesget.kurako.desktop"
install -m 0644 "$PACKAGING_DIR/com.tesget.kurako.metainfo.xml" \
  "$PACKAGE_ROOT/usr/share/metainfo/com.tesget.kurako.metainfo.xml"
install -m 0644 "$PACKAGING_DIR/com.tesget.kurako.png" \
  "$PACKAGE_ROOT/usr/share/icons/hicolor/512x512/apps/com.tesget.kurako.png"
install -m 0644 "$ROOT_DIR/LICENSE" "$PACKAGE_ROOT/usr/share/doc/kurako/copyright"
if [[ -f "$ROOT_DIR/CHANGELOG.md" ]]; then
  gzip -9cn "$ROOT_DIR/CHANGELOG.md" > "$PACKAGE_ROOT/usr/share/doc/kurako/changelog.gz"
  chmod 0644 "$PACKAGE_ROOT/usr/share/doc/kurako/changelog.gz"
fi
find "$PACKAGE_ROOT" -type d -exec chmod 0755 {} +
chmod 0755 "$PACKAGE_ROOT/opt/kurako/kurako"

# Flutter plugin CMake targets may preserve an absolute RUNPATH to the build
# tree. Rewrite only the package copy so the verified Release bundle remains
# untouched and installed plugins resolve the colocated Flutter engine.
while IFS= read -r -d '' elf_file; do
  if file -Lb "$elf_file" | grep -q '^ELF '; then
    elf_rpath="$(patchelf --print-rpath "$elf_file" 2>/dev/null || true)"
    case "$elf_rpath" in
      /*)
        patchelf --set-rpath '$ORIGIN' "$elf_file"
        ;;
    esac
  fi
done < <(find "$PACKAGE_ROOT/opt/kurako" -type f -print0)

cat > "$WORK_DIR/control.source" <<'CONTROL_SOURCE'
Source: kurako
Section: video
Priority: optional
Maintainer: Tesget512 <55989593+Tesget512@users.noreply.github.com>
Standards-Version: 4.6.2
Homepage: https://github.com/Tesget512/Kurako

Package: kurako
Architecture: any
Description: Experimental Linux build of Kurako anime library and player
 Kurako organizes and plays local, SMB, and WebDAV anime libraries with
 Bangumi metadata, subtitle support, and download management. This Linux
 package is experimental and currently provided only as an x86_64 Debian package.
CONTROL_SOURCE
cp "$WORK_DIR/control.source" "$WORK_DIR/debian/control"
cp "$WORK_DIR/control.source" "$DEBIAN_DIR/control"
test -f "$WORK_DIR/debian/control"

mapfile -d '' ELF_FILES < <(
  find "$PACKAGE_ROOT/opt/kurako" -type f -print0 | while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -q '^ELF '; then
      printf '%s\0' "$candidate"
    fi
  done
)
if [[ ${#ELF_FILES[@]} -eq 0 ]]; then
  echo "No ELF files found in package root." >&2
  exit 1
fi
SHLIB_ARGS=()
for elf_file in "${ELF_FILES[@]}"; do
  SHLIB_ARGS+=("-e$elf_file")
done

cd "$WORK_DIR"
SHLIB_OUTPUT="$(
  dpkg-shlibdeps -O -l"$PACKAGE_ROOT/opt/kurako/lib" "${SHLIB_ARGS[@]}" \
    2> "$DEPENDENCY_LOG"
)"
if grep -Eiq 'cannot find library|no dependency information found' "$DEPENDENCY_LOG"; then
  echo "dpkg-shlibdeps could not resolve all runtime libraries:" >&2
  cat "$DEPENDENCY_LOG" >&2
  exit 1
fi
DEPENDENCIES="${SHLIB_OUTPUT#shlibs:Depends=}"
if [[ -z "$DEPENDENCIES" || "$DEPENDENCIES" == "$SHLIB_OUTPUT" ]]; then
  echo "dpkg-shlibdeps did not produce a dependency list." >&2
  exit 1
fi
if ! printf '%s' "$DEPENDENCIES" | tr ',' '\n' | sed 's/^ *//' | \
  grep -qx 'desktop-file-utils'; then
  DEPENDENCIES="$DEPENDENCIES, desktop-file-utils"
fi
INSTALLED_SIZE="$(du -sk "$PACKAGE_ROOT" | awk '{print $1}')"
cat > "$DEBIAN_DIR/control" <<CONTROL
Package: kurako
Version: $VERSION
Section: video
Priority: optional
Architecture: $DEB_ARCH
Maintainer: Tesget512 <55989593+Tesget512@users.noreply.github.com>
Installed-Size: $INSTALLED_SIZE
Depends: $DEPENDENCIES
Homepage: https://github.com/Tesget512/Kurako
Description: Experimental Linux build of Kurako anime library and player
 Kurako organizes and plays local, SMB, and WebDAV anime libraries with
 Bangumi metadata, subtitle support, and download management. This Linux
 package is experimental and currently provided only as an x86_64 Debian package.
CONTROL

(
  cd "$PACKAGE_ROOT"
  find opt usr -type f -print0 | sort -z | xargs -0 md5sum > DEBIAN/md5sums
)
chmod 0644 "$DEBIAN_DIR/control" "$DEBIAN_DIR/md5sums"

mkdir -p "$OUT_DIR"
rm -f "$PACKAGE_PATH"
dpkg-deb --build --root-owner-group "$PACKAGE_ROOT" "$PACKAGE_PATH"
dpkg-deb --info "$PACKAGE_PATH" >/dev/null
dpkg-deb --contents "$PACKAGE_PATH" >/dev/null

AUDIT_DIR="$WORK_DIR/audit"
rm -rf "$AUDIT_DIR"
mkdir -p "$AUDIT_DIR"
dpkg-deb --extract "$PACKAGE_PATH" "$AUDIT_DIR"
while IFS= read -r -d '' elf_file; do
  if file -Lb "$elf_file" | grep -q '^ELF '; then
    elf_rpath="$(patchelf --print-rpath "$elf_file" 2>/dev/null || true)"
    case "$elf_rpath" in
      /*)
        echo "Absolute ELF RPATH/RUNPATH in Debian package: $elf_file: $elf_rpath" >&2
        exit 1
        ;;
    esac
  fi
done < <(find "$AUDIT_DIR" -type f -print0)

PACKAGE_ARCH="$(dpkg-deb -f "$PACKAGE_PATH" Architecture)"
PACKAGE_VERSION="$(dpkg-deb -f "$PACKAGE_PATH" Version)"
PACKAGE_DEPENDS="$(dpkg-deb -f "$PACKAGE_PATH" Depends)"
if [[ "$PACKAGE_ARCH" != "$DEB_ARCH" || "$PACKAGE_VERSION" != "$VERSION" ]]; then
  echo "Unexpected package metadata: version=$PACKAGE_VERSION architecture=$PACKAGE_ARCH" >&2
  exit 1
fi
if [[ "$PACKAGE_DEPENDS" != "$DEPENDENCIES" ]]; then
  echo "Package dependency metadata changed unexpectedly." >&2
  exit 1
fi

printf 'Debian package ready:\n  %s\n  version: %s\n  architecture: %s\n  dependencies: %s\n  dependency log: %s\n' \
  "$PACKAGE_PATH" "$PACKAGE_VERSION" "$PACKAGE_ARCH" "$PACKAGE_DEPENDS" "$DEPENDENCY_LOG"
