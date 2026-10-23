#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/Kurako-Linux-<version>-<arch>.deb" >&2
  exit 2
fi

DEB_PATH="$(realpath "$1")"
if [[ ! -f "$DEB_PATH" ]]; then
  echo "Debian package not found: $DEB_PATH" >&2
  exit 1
fi
if [[ "$(uname -s)" != "Linux" ]] || ! grep -qi microsoft /proc/version; then
  echo "This validation script must run inside WSL2." >&2
  exit 1
fi

for command_name in \
  appstreamcli debsums desktop-file-validate dpkg dpkg-deb file ldd \
  md5sum patchelf sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
done

if [[ "${KURAKO_WSL_GUI:-0}" == "1" ]]; then
  if [[ "${KURAKO_WSL_INSTALL:-0}" != "1" ]]; then
    echo "KURAKO_WSL_GUI=1 also requires KURAKO_WSL_INSTALL=1." >&2
    exit 1
  fi
  for command_name in gio pactl pgrep xdg-mime xwininfo; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Required WSLg command not found: $command_name" >&2
      exit 1
    fi
  done
fi

PACKAGE_NAME="$(dpkg-deb -f "$DEB_PATH" Package)"
PACKAGE_VERSION="$(dpkg-deb -f "$DEB_PATH" Version)"
PACKAGE_ARCH="$(dpkg-deb -f "$DEB_PATH" Architecture)"
if [[ "$PACKAGE_NAME" != "kurako" ]]; then
  echo "Unexpected package name: $PACKAGE_NAME" >&2
  exit 1
fi
case "$PACKAGE_ARCH" in
  amd64)
    ELF_ARCH_PATTERN='x86-64'
    ;;
  arm64)
    ELF_ARCH_PATTERN='aarch64'
    ;;
  *)
    echo "Unsupported Debian package architecture: $PACKAGE_ARCH" >&2
    exit 1
    ;;
esac
if [[ "$PACKAGE_ARCH" != "$(dpkg --print-architecture)" ]]; then
  echo "Package architecture $PACKAGE_ARCH does not match WSL architecture $(dpkg --print-architecture)." >&2
  exit 1
fi
if ! dpkg-deb -f "$DEB_PATH" Depends | tr ',' '\n' | sed 's/^ *//' | \
  grep -qx 'desktop-file-utils'; then
  echo "Missing desktop-file-utils dependency for kurako:// registration." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d -t kurako-deb-wsl.XXXXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
CONTROL_DIR="$WORK_DIR/control"
PACKAGE_ROOT="$WORK_DIR/root"
mkdir -p "$CONTROL_DIR" "$PACKAGE_ROOT"
dpkg-deb --control "$DEB_PATH" "$CONTROL_DIR"
dpkg-deb --extract "$DEB_PATH" "$PACKAGE_ROOT"

if find "$CONTROL_DIR" -maxdepth 1 -type f \
  \( -name preinst -o -name postinst -o -name prerm -o -name postrm \) \
  -print -quit | grep -q .; then
  echo "Unexpected Debian maintainer script found." >&2
  exit 1
fi

(
  cd "$PACKAGE_ROOT"
  md5sum -c "$CONTROL_DIR/md5sums" >/dev/null
)
desktop-file-validate \
  "$PACKAGE_ROOT/usr/share/applications/com.tesget.kurako.desktop"
appstreamcli validate --no-net \
  "$PACKAGE_ROOT/usr/share/metainfo/com.tesget.kurako.metainfo.xml"

if dpkg-deb --contents "$DEB_PATH" | grep -Ev '^[^ ]+ +root/root +'; then
  echo "Debian package contains entries not owned by root:root." >&2
  exit 1
fi

ELF_COUNT=0
while IFS= read -r -d '' elf_file; do
  if file -Lb "$elf_file" | grep -q '^ELF '; then
    ELF_COUNT=$((ELF_COUNT + 1))
    if ! file -Lb "$elf_file" | grep -q "$ELF_ARCH_PATTERN"; then
      echo "Unexpected ELF architecture: $elf_file: $(file -Lb "$elf_file")" >&2
      exit 1
    fi
    elf_rpath="$(patchelf --print-rpath "$elf_file" 2>/dev/null || true)"
    case "$elf_rpath" in
      /*)
        echo "Absolute ELF RPATH/RUNPATH: $elf_file: $elf_rpath" >&2
        exit 1
        ;;
    esac
  fi
done < <(find "$PACKAGE_ROOT" -type f -print0)
if [[ "$ELF_COUNT" -eq 0 ]]; then
  echo "No ELF files found in Debian package." >&2
  exit 1
fi

apt-get -s install "$DEB_PATH" >/dev/null

if [[ "${KURAKO_WSL_INSTALL:-0}" == "1" ]]; then
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "KURAKO_WSL_INSTALL=1 requires root." >&2
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "$DEB_PATH"
  if [[ "$(dpkg-query -W -f='${Status}' kurako)" != "install ok installed" ]]; then
    echo "Kurako is not installed correctly." >&2
    exit 1
  fi
  if [[ "$(dpkg-query -W -f='${Version}' kurako)" != "$PACKAGE_VERSION" ]]; then
    echo "Installed Kurako version does not match the package." >&2
    exit 1
  fi
  debsums -s kurako
  dpkg -V kurako

  MISSING_DEPENDENCIES=0
  INSTALLED_ELF_COUNT=0
  while IFS= read -r -d '' elf_file; do
    if file -Lb "$elf_file" | grep -q '^ELF '; then
      INSTALLED_ELF_COUNT=$((INSTALLED_ELF_COUNT + 1))
      if ldd "$elf_file" | grep -q 'not found'; then
        echo "Missing installed dependency: $elf_file" >&2
        ldd "$elf_file" | grep 'not found' >&2
        MISSING_DEPENDENCIES=1
      fi
      elf_rpath="$(patchelf --print-rpath "$elf_file" 2>/dev/null || true)"
      case "$elf_rpath" in
        /*)
          echo "Installed ELF has absolute RPATH/RUNPATH: $elf_file: $elf_rpath" >&2
          exit 1
          ;;
      esac
    fi
  done < <(find /opt/kurako -type f -print0)
  if [[ "$MISSING_DEPENDENCIES" -ne 0 || "$INSTALLED_ELF_COUNT" -ne "$ELF_COUNT" ]]; then
    echo "Installed ELF dependency audit failed." >&2
    exit 1
  fi
  apt-get -s remove kurako | grep -q '^Remv kurako '
fi

if [[ "${KURAKO_WSL_GUI:-0}" == "1" ]]; then
  if [[ ! -S /tmp/.X11-unix/X0 || ! -S /mnt/wslg/PulseServer ]]; then
    echo "WSLg X11 or PulseAudio socket is unavailable." >&2
    exit 1
  fi

  export DISPLAY="${DISPLAY:-:0}"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  export PULSE_SERVER="${PULSE_SERVER:-unix:/mnt/wslg/PulseServer}"
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
  export GDK_BACKEND=x11
  unset WAYLAND_DISPLAY

  if ! pactl info >/dev/null; then
    echo "Cannot connect to WSLg PulseAudio." >&2
    exit 1
  fi
  if [[ "$(xdg-mime query default x-scheme-handler/kurako)" != \
    "com.tesget.kurako.desktop" ]]; then
    echo "Kurako URI handler is not registered." >&2
    exit 1
  fi
  if [[ -z "$(xdg-mime query default x-scheme-handler/http)" || \
    -z "$(xdg-mime query default x-scheme-handler/https)" ]]; then
    echo "A Linux HTTP/HTTPS browser handler is required for OAuth." >&2
    exit 1
  fi

  count_live_kurako_processes() {
    local process_dir process_state process_exe
    local count=0
    for process_dir in /proc/[0-9]*; do
      [[ -r "$process_dir/stat" && -e "$process_dir/exe" ]] || continue
      process_state="$(awk '{print $3}' "$process_dir/stat" 2>/dev/null || true)"
      [[ "$process_state" != "Z" ]] || continue
      process_exe="$(readlink -f "$process_dir/exe" 2>/dev/null || true)"
      if [[ "$process_exe" == "/opt/kurako/kurako" ]]; then
        count=$((count + 1))
      fi
    done
    printf '%s\n' "$count"
  }

  GUI_LOG="$WORK_DIR/kurako-wslg.log"
  pkill -x kurako 2>/dev/null || true
  for _ in {1..20}; do
    [[ "$(count_live_kurako_processes)" -eq 0 ]] && break
    sleep 1
  done
  if [[ "$(count_live_kurako_processes)" -ne 0 ]]; then
    echo "A previous Kurako process did not stop." >&2
    exit 1
  fi
  nohup /usr/bin/kurako >"$GUI_LOG" 2>&1 </dev/null &
  GUI_PID=$!
  for _ in {1..20}; do
    if kill -0 "$GUI_PID" 2>/dev/null && \
      xwininfo -root -tree | grep -q '"Kurako"'; then
      break
    fi
    sleep 1
  done
  kill -0 "$GUI_PID"
  if ! xwininfo -root -tree | grep -q '"Kurako"'; then
    echo "Kurako WSLg window was not found." >&2
    cat "$GUI_LOG" >&2
    exit 1
  fi
  if grep -q 'Failed to create AudioController' "$GUI_LOG"; then
    echo "Kurako failed to create its audio controller." >&2
    cat "$GUI_LOG" >&2
    exit 1
  fi

  PROCESS_COUNT_BEFORE_URI="$(count_live_kurako_processes)"
  gio open 'kurako://oauth/callback?code=wsl-gui-validation&state=wsl-gui-validation'
  sleep 3
  PROCESS_COUNT_AFTER_URI="$(count_live_kurako_processes)"
  if [[ "$PROCESS_COUNT_BEFORE_URI" -ne 1 || "$PROCESS_COUNT_AFTER_URI" -ne 1 ]]; then
    printf 'Kurako WSLg URI single-instance validation failed: before=%s after=%s\n' \
      "$PROCESS_COUNT_BEFORE_URI" "$PROCESS_COUNT_AFTER_URI" >&2
    exit 1
  fi
fi

printf 'WSL Debian package validation passed:\n  package: %s\n  version: %s\n  architecture: %s\n  sha256: %s\n  ELF files: %s\n  installed validation: %s\n  WSLg GUI validation: %s\n' \
  "$DEB_PATH" "$PACKAGE_VERSION" "$PACKAGE_ARCH" \
  "$(sha256sum "$DEB_PATH" | awk '{print $1}')" "$ELF_COUNT" \
  "${KURAKO_WSL_INSTALL:-0}" "${KURAKO_WSL_GUI:-0}"
