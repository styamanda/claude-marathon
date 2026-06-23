#!/usr/bin/env bash
set -uo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR=$(cd -P "$(dirname "$SOURCE")" && pwd)
  SOURCE=$(readlink "$SOURCE")
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR=$(cd -P "$(dirname "$SOURCE")" && pwd)

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="${BIN_DIR:-$PREFIX/bin}"

usage() {
  cat <<'USAGE'
Usage: ./install.sh

Environment overrides:
  PREFIX=/opt/local        Install under PREFIX/bin
  BIN_DIR=/custom/bin      Install symlinks into an explicit directory
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

mkdir -p "$BIN_DIR" || {
  echo "error: could not create $BIN_DIR" >&2
  exit 1
}

for cmd in claude-marathon marathon-launchd marathon-queue; do
  chmod +x "$SCRIPT_DIR/$cmd" 2>/dev/null || true
  ln -sf "$SCRIPT_DIR/$cmd" "$BIN_DIR/$cmd" || {
    echo "error: could not link $cmd into $BIN_DIR" >&2
    exit 1
  }
done

echo "Installed claude-marathon commands into $BIN_DIR"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "WARNING: $BIN_DIR is not on PATH."
    echo "Add this to your shell profile:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

echo
"$SCRIPT_DIR/claude-marathon" --doctor
