#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/work" "$TMP/logs" "$TMP/locks"

cat > "$TMP/fake-claude.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail

COUNT_FILE="$DEMO_COUNT_FILE"
COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNT_FILE"

if (( COUNT == 1 )); then
  RESET=$(( $(date +%s) + 3 ))
  printf '{"type":"result","subtype":"error","is_error":true,"resetsAt":%s,"result":"Synthetic demo usage limit reached."}\n' "$RESET"
  exit 0
fi

printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Limit cleared. Finishing the demo task."},{"type":"tool_use","name":"Write","input":{"file_path":".marathon-done"}}]}}'
: > .marathon-done
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"Demo task complete."}'
FAKE
chmod +x "$TMP/fake-claude.sh"

echo "Running a simulated claude-marathon limit/reset demo..."
echo "  workdir: $TMP/work"
echo "  logs:    $TMP/logs"
echo

DEMO_COUNT_FILE="$TMP/count" \
MARATHON_CLAUDE_CMD="$TMP/fake-claude.sh" \
MARATHON_LOG_DIR="$TMP/logs" \
MARATHON_LOCK_DIR="$TMP/locks" \
MARATHON_NOTIFY=off \
MARATHON_HEARTBEAT=0 \
MARATHON_MAX_ITERS=3 \
MARATHON_MAX_LIMIT_WAITS=3 \
MARATHON_BUFFER=0 \
MARATHON_NOW_CMD= \
MARATHON_SESSION_PROBE_CMD=true \
  "$ROOT/claude-marathon" "Demo: wait through one synthetic usage limit, then finish." "$TMP/work"

echo
echo "Recent demo logs:"
MARATHON_LOG_DIR="$TMP/logs" "$ROOT/claude-marathon" --logs
