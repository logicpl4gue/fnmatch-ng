#!/usr/bin/env sh
#
# collect_env.sh — M0 environment metadata capture (plan §9, §35).
#   Writes results/baseline/env.json: OS / CPU / arch / compiler / libc.
#
# Usage:  scripts/collect_env.sh     (run from anywhere)
# POSIX sh; runs in Git Bash, MSYS2, Cygwin, WSL, or any Unix-like shell.
# On a shell with no POSIX tools, adapt or provide a native equivalent.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/results/baseline/env.json"
mkdir -p "$(dirname -- "$OUT")"

# esc <value> — JSON-escape a single-line value (backslash, quote).
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# jsval <cmd...> — first non-empty stdout line, JSON-escaped. "" if absent.
jsval() {
  "$@" 2>/dev/null | sed '/^[[:space:]]*$/d' | head -n 1 | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# --- raw facts ---------------------------------------------------------------
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
OS_NAME=$(uname -s 2>/dev/null || true)
OS_REL=$(uname -r 2>/dev/null || true)
ARCH=$(uname -m 2>/dev/null || true)

CPU_MODEL=""
CPU_CORES=""
if [ -r /proc/cpuinfo ]; then
  CPU_MODEL=$(awk -F: '/^model name/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }' /proc/cpuinfo 2>/dev/null || true)
  CPU_CORES=$(awk '/^cpu cores/ { print $4; exit }' /proc/cpuinfo 2>/dev/null || true)
fi
NPROC=$(nproc 2>/dev/null || true)

COMPILER_NAME=""
COMPILER_VERSION=""
COMPILER_TARGET=""
if command -v gcc >/dev/null 2>&1; then
  COMPILER_NAME="gcc"
  COMPILER_VERSION=$(gcc --version 2>/dev/null | head -n 1)
  COMPILER_TARGET=$(gcc -dumpmachine 2>/dev/null || true)
elif command -v clang >/dev/null 2>&1; then
  COMPILER_NAME="clang"
  COMPILER_VERSION=$(clang --version 2>/dev/null | head -n 1)
  COMPILER_TARGET=$(clang -dumpmachine 2>/dev/null || true)
fi

# libc: glibc via ldd --version, else platform runtime by OS name
LIBC="not detected"
if ldd --version 2>/dev/null | head -n 1 | grep -qi glibc; then
  LIBC=$(ldd --version 2>/dev/null | head -n 1)
else
  case "$OS_NAME" in
    MINGW*|MSYS*) LIBC="none (MinGW-w64 on MSYS2 runtime)" ;;
    CYGWIN*)      LIBC="cygwin1.dll (Cygwin)" ;;
  esac
fi

# --- emit results/baseline/env.json -------------------------------------------
{
  printf '{\n'
  printf '  "timestamp": "%s",\n' "$TS"
  printf '  "os": {\n'
  printf '    "name": "%s",\n' "$(esc "$OS_NAME")"
  printf '    "release": "%s",\n' "$(esc "$OS_REL")"
  printf '    "arch": "%s",\n' "$(esc "$ARCH")"
  printf '    "libc": "%s"\n' "$(esc "$LIBC")"
  printf '  },\n'
  printf '  "cpu": {\n'
  printf '    "model": "%s",\n' "$(esc "$CPU_MODEL")"
  printf '    "cores_physical": "%s",\n' "$(esc "$CPU_CORES")"
  printf '    "cores_logical": "%s"\n' "$(esc "$NPROC")"
  printf '  },\n'
  printf '  "compiler": {\n'
  printf '    "name": "%s",\n' "$(esc "$COMPILER_NAME")"
  printf '    "version": "%s",\n' "$(esc "$COMPILER_VERSION")"
  printf '    "target": "%s"\n' "$(esc "$COMPILER_TARGET")"
  printf '  }\n'
  printf '}\n'
} > "$OUT"

printf 'wrote %s\n' "$OUT"
