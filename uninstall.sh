#!/usr/bin/env bash
set -uo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="${BIN_DIR:-$PREFIX/bin}"
REMOVE_LOGS=0
REMOVE_LOCKS=0

usage() {
  cat <<'USAGE'
Usage: ./uninstall.sh [--logs] [--locks] [--all]

Removes claude-marathon command symlinks from BIN_DIR (default ~/.local/bin).
Logs and locks are preserved unless explicitly requested.

Options:
  --logs      Also remove ~/.claude/marathon-logs (or MARATHON_LOG_DIR)
  --locks     Also remove ~/.claude/marathon-locks (or MARATHON_LOCK_DIR)
  --all       Remove command symlinks, logs, and locks
  -h, --help  Show this help

Environment overrides:
  PREFIX=/opt/local        Remove from PREFIX/bin
  BIN_DIR=/custom/bin      Remove from an explicit directory
USAGE
}

while [[ "${1:-}" == -* ]]; do
  case "$1" in
    --logs) REMOVE_LOGS=1; shift ;;
    --locks) REMOVE_LOCKS=1; shift ;;
    --all) REMOVE_LOGS=1; REMOVE_LOCKS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done

for cmd in claude-marathon marathon-launchd marathon-queue; do
  path="$BIN_DIR/$cmd"
  if [[ -L "$path" ]]; then
    rm -f "$path"
    echo "Removed symlink: $path"
  elif [[ -e "$path" ]]; then
    echo "Skipped non-symlink: $path" >&2
  else
    echo "Not installed: $path"
  fi
done

if (( REMOVE_LOGS )); then
  dir="${MARATHON_LOG_DIR:-$HOME/.claude/marathon-logs}"
  rm -rf "$dir"
  echo "Removed logs: $dir"
fi

if (( REMOVE_LOCKS )); then
  dir="${MARATHON_LOCK_DIR:-$HOME/.claude/marathon-locks}"
  rm -rf "$dir"
  echo "Removed locks: $dir"
fi
