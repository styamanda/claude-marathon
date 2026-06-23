#!/usr/bin/env bash
# marathon-lib.sh — pure functions for claude-marathon.
# Side-effect free on source: defines vars + functions only.

: "${MARATHON_MAX_ITERS:=20}"
: "${MARATHON_TIMEOUT:=7200}"
: "${MARATHON_FALLBACK_SLEEP:=300}"
: "${MARATHON_MAX_LIMIT_WAITS:=96}"
: "${MARATHON_BUFFER:=60}"
: "${MARATHON_SENTINEL:=.marathon-done}"
: "${MARATHON_LOG_DIR:=$HOME/.claude/marathon-logs}"
: "${MARATHON_CLAUDE_CMD:=claude}"
: "${MARATHON_SLEEP_CMD:=sleep}"
: "${MARATHON_NOTIFY:=auto}"
: "${MARATHON_LOCK_DIR:=$HOME/.claude/marathon-locks}"
: "${MARATHON_HEARTBEAT:=300}"
: "${MARATHON_WAIT_POLL:=60}"

marathon_version() {
  echo "claude-marathon 0.1.0"
}

# contains_smart_quotes <str> -> rc 0 if str contains a curly/smart quote.
# Editors and terminals silently turn "..." into “...”; the shell does NOT
# treat curly quotes as quoting, so a quoted task arg gets split into words
# and the workdir gets eaten. We detect this so we can warn instead of mangle.
contains_smart_quotes() {
  case "$1" in
    *“*|*”*|*‘*|*’*) return 0 ;;
    *) return 1 ;;
  esac
}

# open_log_terminal <logfile> -> opens a macOS Terminal window tailing <logfile>.
# Uses tail -F (follow by name, retry) so it works even before the file exists.
# rc 1 if osascript is unavailable (non-macOS); the caller treats that as a no-op.
open_log_terminal() {
  local logfile="$1"
  command -v osascript >/dev/null 2>&1 || return 1
  osascript >/dev/null 2>&1 <<EOF
tell application "Terminal"
  activate
  do script "echo '── claude-marathon live log ─────────────'; tail -F '${logfile}'"
end tell
EOF
}

# marathon_lock_path <workdir> -> lock directory path for that workdir
marathon_lock_path() {
  local key
  key=$(printf '%s' "$1" | sed 's#[^A-Za-z0-9]#_#g')
  printf '%s/%s.lock' "${MARATHON_LOCK_DIR:-$HOME/.claude/marathon-locks}" "$key"
}

# lock_held <workdir> -> 0 if a LIVE marathon currently holds this workdir's lock
lock_held() {
  local lock holder
  lock=$(marathon_lock_path "$1")
  holder=$(cat "$lock/pid" 2>/dev/null)
  [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null
}

# acquire_lock <workdir> -> 0 acquired, 1 already held by a live process.
# Uses mkdir as the atomic primitive; reclaims a stale lock whose holder died.
acquire_lock() {
  local lock holder
  lock=$(marathon_lock_path "$1")
  mkdir -p "$(dirname "$lock")"
  if mkdir "$lock" 2>/dev/null; then
    echo $$ > "$lock/pid"
    printf '%s\n' "$1" > "$lock/workdir"
    return 0
  fi
  holder=$(cat "$lock/pid" 2>/dev/null)
  if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
    return 1
  fi
  # stale lock — reclaim it
  echo $$ > "$lock/pid"
  printf '%s\n' "$1" > "$lock/workdir"
  return 0
}

# release_lock <workdir> -> removes the lock only if this process owns it
release_lock() {
  local lock holder
  lock=$(marathon_lock_path "$1")
  holder=$(cat "$lock/pid" 2>/dev/null)
  [[ "$holder" == "$$" ]] && rm -rf "$lock"
  return 0
}

# install_cleanup_traps <workdir> -> release the lock on exit, AND make the
# process actually TERMINATE on INT/TERM. A bare `trap '…' TERM` runs the handler
# and then RESUMES the script — so `launchctl bootout`/`kill` would release the
# lock but leave the loop running as an orphan, and the freed lock then lets a
# second marathon start on top (the pile-up). Here we release the lock, restore
# the signal's default action, and re-raise it so the process exits with the
# right status; the EXIT trap stays armed and is a harmless idempotent re-release.
install_cleanup_traps() {
  local wd
  printf -v wd '%q' "$1"
  trap "release_lock $wd" EXIT
  trap "release_lock $wd; trap - INT;  kill -INT  \$\$" INT
  trap "release_lock $wd; trap - TERM; kill -TERM \$\$" TERM
}

# _marathon_descendants <pid> -> echo <pid> and every descendant pid, so a stop
# can signal the whole tree (incl. the underlying `claude`), not just the top.
_marathon_descendants() {
  local pid="$1" child
  if command -v pgrep >/dev/null 2>&1; then
    for child in $(pgrep -P "$pid" 2>/dev/null); do
      _marathon_descendants "$child"
    done
  fi
  echo "$pid"
}

# marathon_status -> list every workdir lock with its pid, liveness, and workdir.
marathon_status() {
  local dir="${MARATHON_LOCK_DIR:-$HOME/.claude/marathon-locks}"
  local found=0 lock pid wd state
  for lock in "$dir"/*.lock; do
    [[ -d "$lock" ]] || continue
    found=1
    pid=$(cat "$lock/pid" 2>/dev/null)
    wd=$(cat "$lock/workdir" 2>/dev/null)
    [[ -z "$wd" ]] && wd="(unknown workdir)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      state="RUNNING"
    else
      state="STALE  "
    fi
    echo "${state}  pid=${pid:-?}  ${wd}"
  done
  (( found )) || echo "(no marathons running)"
}

# marathon_log_files -> newest-first log paths, rc 1 when no logs exist.
marathon_log_files() {
  local dir="${MARATHON_LOG_DIR:-$HOME/.claude/marathon-logs}"
  [[ -d "$dir" ]] || return 1
  (
    shopt -s nullglob
    local -a files=( "$dir"/*.log )
    (( ${#files[@]} )) || exit 1
    ls -t "${files[@]}"
  )
}

# marathon_latest_log -> newest log path only.
marathon_latest_log() {
  marathon_log_files | sed -n '1p'
}

# marathon_logs [limit] -> short newest-first log listing.
marathon_logs() {
  local limit="${1:-10}" dir="${MARATHON_LOG_DIR:-$HOME/.claude/marathon-logs}"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=10
  local files file n=0 stamp size last
  files=$(marathon_log_files 2>/dev/null) || {
    echo "(no marathon logs in $dir)"
    return 0
  }
  echo "Recent marathon logs (newest first):"
  while IFS= read -r file; do
    (( n++ ))
    (( n > limit )) && break
    stamp=$(date -r "$file" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "unknown-time")
    size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
    last=$(tail -n 1 "$file" 2>/dev/null)
    printf '  %s  %s bytes  %s\n' "$stamp" "${size:-0}" "$file"
    [[ -n "$last" ]] && printf '    last: %s\n' "$last"
  done <<< "$files"
}

# marathon_tail [lines] -> tail the newest log. Follows by default; tests can set
# MARATHON_TAIL_FOLLOW=0 to print once and exit.
marathon_tail() {
  local lines="${1:-80}" latest
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=80
  latest=$(marathon_latest_log 2>/dev/null) || {
    echo "No marathon logs found in ${MARATHON_LOG_DIR:-$HOME/.claude/marathon-logs}." >&2
    return 1
  }
  echo "Tailing latest marathon log: $latest" >&2
  if [[ "${MARATHON_TAIL_FOLLOW:-1}" == "0" ]]; then
    tail -n "$lines" "$latest"
  else
    tail -n "$lines" -F "$latest"
  fi
}

_marathon_command_available() {
  local cmd="$1"
  if [[ "$cmd" == */* ]]; then
    [[ -x "$cmd" ]]
  else
    command -v "$cmd" >/dev/null 2>&1
  fi
}

_marathon_truncate() {
  local s="$1" max="${2:-96}"
  s=${s//$'\n'/ }
  if (( ${#s} > max && max > 3 )); then
    printf '%s...' "${s:0:max-3}"
  else
    printf '%s' "$s"
  fi
}

_marathon_plist_extract() {
  local plist="$1" key="$2"
  [[ -f "$plist" ]] || return 1
  command -v plutil >/dev/null 2>&1 || return 1
  plutil -extract "$key" raw "$plist" 2>/dev/null
}

# marathon_launchd_jobs -> list loaded com.claude-marathon LaunchAgents and the
# exact bootout command for each label. Uses plist metadata when the LaunchAgent
# file still exists, but still lists labels from launchctl when it does not.
marathon_launchd_jobs() {
  local launchctl_cmd="${MARATHON_LAUNCHCTL_CMD:-launchctl}"
  local uid="${MARATHON_GUI_UID:-$(id -u)}"
  if ! _marathon_command_available "$launchctl_cmd"; then
    echo "(launchd unavailable: launchctl not found)"
    return 0
  fi

  local rows
  rows=$("$launchctl_cmd" list 2>/dev/null \
    | awk '$3 ~ /^com[.]claude-marathon[.]/ {print $1 "\t" $2 "\t" $3}')
  if [[ -z "$rows" ]]; then
    echo "(no launchd marathon jobs)"
    return 0
  fi

  echo "launchd marathon jobs:"
  local pid status label state plist workdir log queue task
  while IFS=$'\t' read -r pid status label; do
    [[ -n "$label" ]] || continue
    if [[ "$pid" == "-" ]]; then
      state="EXITED  status=${status:-?}"
    else
      state="RUNNING pid=${pid:-?} status=${status:-?}"
    fi
    printf '  %-24s %s\n' "$state" "$label"

    plist="$HOME/Library/LaunchAgents/${label}.plist"
    workdir=$(_marathon_plist_extract "$plist" "EnvironmentVariables.MARATHON_WORKDIR")
    log=$(_marathon_plist_extract "$plist" "StandardOutPath")
    queue=$(_marathon_plist_extract "$plist" "EnvironmentVariables.MARATHON_QUEUE")
    task=$(_marathon_plist_extract "$plist" "EnvironmentVariables.MARATHON_TASK")

    [[ -n "$workdir" ]] && printf '    workdir: %s\n' "$workdir"
    if [[ -n "$queue" ]]; then
      printf '    queue:   %s\n' "$queue"
    elif [[ -n "$task" ]]; then
      printf '    task:    %s\n' "$(_marathon_truncate "$task" 96)"
    fi
    [[ -n "$log" ]] && printf '    log:     %s\n' "$log"
    printf '    stop:    launchctl bootout gui/%s/%s\n' "$uid" "$label"
  done <<< "$rows"
}

_marathon_doctor_line() {
  local status="$1" name="$2" detail="${3:-}"
  if [[ -n "$detail" ]]; then
    printf '%-4s  %-22s %s\n' "$status" "$name" "$detail"
  else
    printf '%-4s  %s\n' "$status" "$name"
  fi
}

# marathon_doctor -> check local prerequisites. Returns 1 only for missing
# requirements that prevent the core runner from working.
marathon_doctor() {
  local fail=0 warn=0 cmd dir
  echo "claude-marathon doctor"

  cmd="${MARATHON_CLAUDE_CMD:-claude}"
  if _marathon_command_available "$cmd"; then
    _marathon_doctor_line "OK" "claude CLI" "$cmd"
  else
    _marathon_doctor_line "FAIL" "claude CLI" "not found: $cmd"
    fail=1
  fi

  if command -v jq >/dev/null 2>&1; then
    _marathon_doctor_line "OK" "jq" "$(command -v jq)"
  else
    _marathon_doctor_line "FAIL" "jq" "required for JSON result parsing"
    fail=1
  fi

  dir="${MARATHON_LOG_DIR:-$HOME/.claude/marathon-logs}"
  if mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
    _marathon_doctor_line "OK" "log directory" "$dir"
  else
    _marathon_doctor_line "FAIL" "log directory" "not writable: $dir"
    fail=1
  fi

  dir="${MARATHON_LOCK_DIR:-$HOME/.claude/marathon-locks}"
  if mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
    _marathon_doctor_line "OK" "lock directory" "$dir"
  else
    _marathon_doctor_line "FAIL" "lock directory" "not writable: $dir"
    fail=1
  fi

  if command -v launchctl >/dev/null 2>&1; then
    _marathon_doctor_line "OK" "launchctl" "$(command -v launchctl)"
  else
    _marathon_doctor_line "WARN" "launchctl" "detached marathon-launchd runs are macOS-only"
    warn=1
  fi

  if command -v caffeinate >/dev/null 2>&1; then
    _marathon_doctor_line "OK" "caffeinate" "$(command -v caffeinate)"
  else
    _marathon_doctor_line "WARN" "caffeinate" "Mac sleep prevention unavailable"
    warn=1
  fi

  if command -v osascript >/dev/null 2>&1; then
    _marathon_doctor_line "OK" "osascript" "$(command -v osascript)"
  else
    _marathon_doctor_line "WARN" "osascript" "desktop notifications and --watch window unavailable"
    warn=1
  fi

  if command -v claude-marathon >/dev/null 2>&1; then
    _marathon_doctor_line "OK" "PATH: claude-marathon" "$(command -v claude-marathon)"
  else
    _marathon_doctor_line "WARN" "PATH: claude-marathon" "not on PATH; invoke via ./claude-marathon or install symlinks"
    warn=1
  fi

  if command -v marathon-launchd >/dev/null 2>&1; then
    _marathon_doctor_line "OK" "PATH: marathon-launchd" "$(command -v marathon-launchd)"
  else
    _marathon_doctor_line "WARN" "PATH: marathon-launchd" "not on PATH; detached launch helper may need ./marathon-launchd"
    warn=1
  fi

  if (( fail )); then
    echo "Result: FAIL"
    return 1
  fi
  if (( warn )); then
    echo "Result: OK with warnings"
  else
    echo "Result: OK"
  fi
  return 0
}

# marathon_stop <workdir> -> stop the marathon for <workdir> and clear its lock.
# SIGTERM first (the cleanup trap exits cleanly, which also lets a launchd job
# self-remove), escalating to SIGKILL if it ignores TERM; signals the whole
# process subtree so the underlying `claude` cannot keep running. Returns 0 if it
# stopped a marathon or cleared a stale lock, 1 if nothing was running.
marathon_stop() {
  local wd="$1" lock holder pids i
  lock=$(marathon_lock_path "$wd")
  holder=$(cat "$lock/pid" 2>/dev/null)
  if [[ -z "$holder" ]]; then
    echo "No marathon running for $wd."
    return 1
  fi
  if ! kill -0 "$holder" 2>/dev/null; then
    echo "Marathon for $wd already exited (stale lock, pid $holder) — cleared."
    rm -rf "$lock"
    return 0
  fi
  pids=$(_marathon_descendants "$holder")
  echo "Stopping marathon for $wd (pid $holder and children)…"
  # shellcheck disable=SC2086  # word-splitting of the pid list is intended
  kill -TERM $pids 2>/dev/null
  for ((i=0; i<20; i++)); do
    kill -0 "$holder" 2>/dev/null || break
    sleep 0.25
  done
  if kill -0 "$holder" 2>/dev/null; then
    echo "  ignored SIGTERM; sending SIGKILL."
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null
    sleep 0.25
  fi
  rm -rf "$lock"
  echo "  stopped."
  return 0
}

# claude_sessions_in_dir <workdir> -> PIDs of `claude` CLI processes whose current
# working directory is exactly <workdir> (i.e. that would share its conversation).
# Best-effort: needs pgrep + lsof; prints nothing if either is missing. Used to
# spot an interactive (VS Code / terminal) Claude session before a marathon starts
# in the same directory — otherwise they collide on the same conversation.
claude_sessions_in_dir() {
  local wd="$1" p cwd self="$$"
  command -v pgrep >/dev/null 2>&1 || return 0
  command -v lsof  >/dev/null 2>&1 || return 0
  for p in $(pgrep -f claude 2>/dev/null); do
    [[ "$p" == "$self" ]] && continue
    cwd=$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    [[ "$cwd" == "$wd" ]] && echo "$p"
  done
}

# detect_dir_collision <workdir> -> PIDs of OTHER live Claude sessions sharing
# <workdir> (empty output = clear to start). Honors MARATHON_ALLOW_SHARED_DIR=1
# (force-allow) and MARATHON_SESSION_PROBE_CMD (override the scanner; for tests).
detect_dir_collision() {
  local wd="$1"
  [[ "${MARATHON_ALLOW_SHARED_DIR:-0}" == "1" ]] && return 0
  if [[ -n "${MARATHON_SESSION_PROBE_CMD:-}" ]]; then
    "$MARATHON_SESSION_PROBE_CMD" "$wd"
    return 0
  fi
  claude_sessions_in_dir "$wd"
}

# parse_reset_epoch <raw> -> Unix epoch of TODAY's reset time, or rc 1 if absent.
# Parses human reset times like "resets 4:20am (Europe/London)" / "resets 8pm".
# Uses the timezone in parentheses if present, else the local zone. Returns the
# epoch for the parsed clock time on today's date (which may be in the past);
# the caller decides whether to trust it (only used when clearly in the future).
parse_reset_epoch() {
  local raw="$1" low tstr ap hm norm tz today epoch
  low=$(printf '%s' "$raw" | tr 'A-Z' 'a-z')
  tstr=$(printf '%s' "$low" | grep -oE 'reset[s]?( at)? [0-9]{1,2}(:[0-9]{2})?(am|pm)' | head -1 \
         | grep -oE '[0-9]{1,2}(:[0-9]{2})?(am|pm)')
  [[ -z "$tstr" ]] && return 1
  ap=$(printf '%s' "$tstr" | grep -oE '(am|pm)$')
  hm=${tstr%$ap}
  [[ "$hm" != *:* ]] && hm="${hm}:00"
  norm="${hm}$(printf '%s' "$ap" | tr 'a-z' 'A-Z')"   # e.g. 4:20AM
  tz=$(printf '%s' "$raw" | grep -oE '\([A-Za-z]+/[A-Za-z_]+\)' | head -1 | tr -d '()')
  [[ -z "$tz" ]] && tz="$(date +%Z)"
  today=$(TZ="$tz" date "+%Y-%m-%d")
  epoch=$(TZ="$tz" date -j -f "%Y-%m-%d %I:%M%p" "$today $norm" "+%s" 2>/dev/null)
  [[ -z "$epoch" ]] && return 1
  printf '%s' "$epoch"
}

# classify_result <raw_output> <exit_code> -> "OK" | "LIMIT <epoch|unknown>" | "ERROR <msg>"
#
# Usage-limit detection for Claude Code (verified against CLI v2.1.183):
#   - The CLI carries the reset time in a JSON field `resetsAt` (Unix epoch
#     seconds, from the `anthropic-ratelimit-unified-reset` response header).
#   - The user-facing text is "usage limit reached" (no pipe-epoch).
# We accept three signals, most precise first:
#   1) a `resetsAt` epoch anywhere in the JSON  -> LIMIT <epoch>
#   2) legacy "usage limit reached|<epoch>" text -> LIMIT <epoch>
#   3) the bare "usage limit reached" phrase     -> LIMIT unknown (use fallback)
classify_result() {
  local raw="$1" exit_code="$2"

  local epoch
  # (1) structured resetsAt field (current CLI), epoch seconds
  epoch=$(printf '%s' "$raw" | jq -r '[.. | .resetsAt? | numbers] | first // empty' 2>/dev/null)
  # (2) legacy pipe-delimited epoch
  if [[ -z "$epoch" ]]; then
    epoch=$(printf '%s' "$raw" | grep -oE 'usage limit reached\|[0-9]+' | head -1 | grep -oE '[0-9]+$')
  fi

  if [[ -n "$epoch" ]]; then
    echo "LIMIT $epoch"
    return 0
  fi
  # (3) a rate/usage/session-limit notification. Verified real CLI message:
  #     "You've hit your session limit · resets 8pm (Europe/London)".
  #     Try to parse the human reset time for a precise sleep; else fallback.
  if printf '%s' "$raw" | grep -qiE "hit your (session|usage|weekly|account) limit|reached your (session|usage|weekly|account) limit|(session|usage|credit|rate)[ -]?limit (reached|exceeded)|usage limit reached"; then
    # Use a parsed reset time only when it is clearly in the future; otherwise
    # (stale/just-passed/ambiguous) report unknown so the loop short-polls.
    local reset_epoch now
    reset_epoch=$(parse_reset_epoch "$raw")
    now=$(date +%s)
    if [[ -n "$reset_epoch" ]] && (( reset_epoch > now + 60 )); then
      echo "LIMIT $reset_epoch"
    else
      echo "LIMIT unknown"
    fi
    return 0
  fi

  local is_err
  is_err=$(printf '%s' "$raw" | jq -r '.is_error // empty' 2>/dev/null)
  if [[ "$is_err" == "true" ]]; then
    local msg
    msg=$(printf '%s' "$raw" | jq -r '.result // .error // "unknown error"' 2>/dev/null)
    [[ -z "$msg" || "$msg" == "null" ]] && msg="unknown error"
    echo "ERROR $msg"
    return 0
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    echo "ERROR exit_code=$exit_code"
    return 0
  fi

  echo "OK"
}

# compute_sleep <epoch> <now> <buffer> <fallback> -> seconds
compute_sleep() {
  local epoch="$1" now="$2" buffer="$3" fallback="$4"
  if ! [[ "$epoch" =~ ^[0-9]+$ ]]; then
    echo "$fallback"
    return 0
  fi
  local diff=$(( epoch - now + buffer ))
  (( diff < 0 )) && diff=0
  echo "$diff"
}

# run_with_timeout <seconds> <cmd...> -> cmd exit code, or 124 if timed out
run_with_timeout() {
  set +e   # this function manages exit codes explicitly; never let a caller's errexit abort the loop
  local secs="$1"; shift
  "$@" &
  local cmd_pid=$!
  local count=0
  while kill -0 "$cmd_pid" 2>/dev/null; do
    if (( count >= secs )); then
      kill -TERM "$cmd_pid" 2>/dev/null
      wait "$cmd_pid" 2>/dev/null
      return 124
    fi
    sleep 1
    ((count++))
  done
  wait "$cmd_pid"
  return $?
}

# marathon_now -> current Unix epoch. Overridable via MARATHON_NOW_CMD so a test
# can feed a simulated clock (e.g. model a system-sleep jump) deterministically.
marathon_now() {
  if [[ -n "${MARATHON_NOW_CMD:-}" ]]; then
    "$MARATHON_NOW_CMD"
  else
    date +%s
  fi
}

# marathon_wait_until <target_epoch> -> wait until the real wall clock reaches
# <target_epoch>, polling in short (MARATHON_WAIT_POLL) chunks. Unlike a single
# `sleep <duration>`, this is RESILIENT TO SYSTEM SLEEP: macOS freezes a sleeping
# countdown while the Mac is asleep, but the wall clock jumps forward across the
# sleep — so the first poll after the Mac wakes sees the target has passed and
# returns at once (a laptop that slept overnight resumes the moment you reopen
# it). Emits a "still waiting" pulse every MARATHON_HEARTBEAT seconds so a long
# limit wait never looks frozen.
marathon_wait_until() {
  local target="$1" now left interval last_pulse
  local poll="${MARATHON_WAIT_POLL:-60}"
  local hb="${MARATHON_HEARTBEAT:-300}"
  last_pulse=$(marathon_now)
  while :; do
    now=$(marathon_now)
    (( now >= target )) && return 0
    if [[ "$hb" =~ ^[0-9]+$ ]] && (( hb > 0 )) && (( now - last_pulse >= hb )); then
      left=$(( target - now ))
      echo "[$(date '+%H:%M:%S')]   … still waiting for usage reset (~$(( left / 60 ))m left, until $(date -r "$target" '+%H:%M:%S' 2>/dev/null))."
      last_pulse=$now
    fi
    interval=$(( target - now ))
    (( interval > poll )) && interval=$poll
    (( interval < 1 )) && interval=1
    "${MARATHON_SLEEP_CMD:-sleep}" "$interval"
  done
}

# notify <title> <message> -> side effect (desktop notification / echo)
notify() {
  local title="$1" msg="$2"
  case "${MARATHON_NOTIFY:-auto}" in
    off)  return 0 ;;
    echo) echo "[notify] ${title}: ${msg}"; return 0 ;;
  esac
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${msg}\" with title \"${title}\"" >/dev/null 2>&1
  else
    echo "[notify] ${title}: ${msg}"
  fi
}

# marathon_heartbeat <interval_secs> -> prints a "still working" line every
# <interval_secs> seconds until killed. With stream-json the live log now shows
# each message/tool call as it happens; this pulse is a gap-filler for silent
# stretches (the model thinking, or a long-running tool that emits no events).
marathon_heartbeat() {
  local interval="$1" elapsed=0
  while sleep "$interval"; do
    elapsed=$((elapsed + interval))
    echo "[$(date '+%H:%M:%S')]   … still working (~$((elapsed / 60))m elapsed)."
  done
}

# marathon_format_stream <outfile> -> read claude stream-json (NDJSON) on stdin;
# narrate human-readable progress to stdout (the live log) and capture the final
# `result` event to <outfile> for classify_result/detect_limit. Falls back to the
# last bare JSON object when no typed result arrives (covers --output-format json,
# error payloads, and the test stubs), and passes non-JSON lines through verbatim.
marathon_format_stream() {
  local outfile="$1" line typ text fallback="" got=0
  : > "$outfile"
  while IFS= read -r line; do
    typ=$(printf '%s' "$line" | jq -r 'if type=="object" then (.type // "") else "" end' 2>/dev/null) || typ=""
    case "$typ" in
      result)
        printf '%s\n' "$line" > "$outfile"; got=1
        printf '[%s] ● result: %s\n' "$(date '+%H:%M:%S')" \
          "$(printf '%s' "$line" | jq -r '.subtype // (if .is_error then "error" else "ok" end)' 2>/dev/null)"
        ;;
      assistant)
        text=$(printf '%s' "$line" | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null)
        [[ -n "$text" ]] && printf '[%s] claude: %s\n' "$(date '+%H:%M:%S')" "$text"
        printf '%s' "$line" \
          | jq -r '.message.content[]? | select(.type=="tool_use") | "🔧 \(.name): \((.input|tostring)[0:120])"' 2>/dev/null \
          | while IFS= read -r t; do [[ -n "$t" ]] && printf '[%s]   %s\n' "$(date '+%H:%M:%S')" "$t"; done
        ;;
      system|user) : ;;
      *)
        if printf '%s' "$line" | jq -e 'type=="object"' >/dev/null 2>&1; then
          fallback="$line"
        elif [[ -n "$line" ]]; then
          printf '%s\n' "$line"
        fi
        ;;
    esac
  done
  (( got )) || { [[ -n "$fallback" ]] && printf '%s\n' "$fallback" > "$outfile"; }
}

# run_iteration <iter> <workdir> <task> <outfile> [resume_id] -> claude exit code
# Iteration 0: seed a fresh conversation, OR resume <resume_id> if given.
# Iterations 1+: always --continue the most recent conversation in workdir.
run_iteration() {
  local iter="$1" workdir="$2" task="$3" outfile="$4" resume_id="${5:-}"
  local sentinel="${MARATHON_SENTINEL:-.marathon-done}"
  local instr="When the ENTIRE task is fully complete and verified, your final action must be to create an empty file named '${sentinel}' in this directory. Do not create it until everything is truly finished."

  local -a cmd
  cmd=( "${MARATHON_CLAUDE_CMD:-claude}" -p --permission-mode bypassPermissions )
  if (( iter == 0 )); then
    if [[ -n "$resume_id" ]]; then
      cmd+=( --resume "$resume_id" "${task}"$'\n\n'"${instr}" )
    else
      cmd+=( "${task}"$'\n\n'"${instr}" )
    fi
  else
    cmd+=( --continue "Continue the task where you left off. ${instr}" )
  fi

  # Escape hatch: revert to the old single-blob capture if streaming misbehaves.
  if [[ "${MARATHON_NO_STREAM:-0}" == 1 ]]; then
    cmd+=( --output-format json )
    ( cd "$workdir" && run_with_timeout "${MARATHON_TIMEOUT:-7200}" "${cmd[@]}" ) > "$outfile" 2>&1
    return $?
  fi
  # Stream NDJSON so the live log shows each message/tool call as it happens. The
  # formatter narrates to stdout (the live log) and captures the final `result`
  # event to "$outfile" for classify_result. stream-json requires --verbose with -p.
  cmd+=( --output-format stream-json --verbose )
  ( cd "$workdir" && run_with_timeout "${MARATHON_TIMEOUT:-7200}" "${cmd[@]}" 2>&1 ) \
    | marathon_format_stream "$outfile"
  return "${PIPESTATUS[0]}"   # claude's exit code (or 124 timeout), not the formatter's
}

# run_marathon <task> [workdir] [resume_id]
#   -> 0 done | 1 error | 2 cap reached | 3 gave up still rate-limited
run_marathon() {
  set +e   # the loop classifies non-zero claude exits (limit/error); never let errexit abort it
  local task="$1" workdir="${2:-$PWD}" resume_id="${3:-}"
  local sentinel="${MARATHON_SENTINEL:-.marathon-done}"
  local max="${MARATHON_MAX_ITERS:-20}"
  local max_limit_waits="${MARATHON_MAX_LIMIT_WAITS:-96}"
  local buffer="${MARATHON_BUFFER:-60}"
  local fallback="${MARATHON_FALLBACK_SLEEP:-300}"
  local logdir="${MARATHON_LOG_DIR:-$HOME/.claude/marathon-logs}"
  local heartbeat="${MARATHON_HEARTBEAT:-300}"

  mkdir -p "$logdir"
  rm -f "$workdir/$sentinel"

  local iter=0 limit_waits=0
  while (( iter < max )); do
    local stamp outfile
    stamp=$(date +%Y%m%d-%H%M%S)
    outfile="$logdir/iter-${iter}-${stamp}.log"

    echo "[$(date '+%H:%M:%S')] → iteration $((iter+1))/${max}: claude is working (live output follows — messages and tool calls stream in below)."
    local hb_pid=""
    if [[ "$heartbeat" =~ ^[0-9]+$ ]] && (( heartbeat > 0 )); then
      marathon_heartbeat "$heartbeat" &
      hb_pid=$!
    fi
    run_iteration "$iter" "$workdir" "$task" "$outfile" "$resume_id"
    local code=$?
    if [[ -n "$hb_pid" ]]; then kill "$hb_pid" 2>/dev/null; wait "$hb_pid" 2>/dev/null; fi

    if [[ -f "$workdir/$sentinel" ]]; then
      notify "claude-marathon" "Task complete after $((iter+1)) iteration(s)."
      echo "DONE after $((iter+1)) iteration(s). Logs: $logdir"
      return 0
    fi

    local raw verdict
    raw=$(cat "$outfile" 2>/dev/null)
    verdict=$(classify_result "$raw" "$code")

    case "$verdict" in
      LIMIT*)
        # A usage/session limit is not progress: sleep and retry WITHOUT
        # consuming the productive iteration budget. Guard runaway limits
        # (e.g. exhausted plan) with a separate cap.
        limit_waits=$((limit_waits + 1))
        if (( limit_waits > max_limit_waits )); then
          notify "claude-marathon" "Gave up: still rate-limited after $max_limit_waits waits."
          echo "GAVE UP: still rate-limited after $max_limit_waits waits. Logs: $logdir"
          return 3
        fi
        local epoch secs now target wake
        epoch=${verdict#LIMIT }
        now=$(date +%s)
        secs=$(compute_sleep "$epoch" "$now" "$buffer" "$fallback")
        target=$(( now + secs ))
        wake=$(date -r "$target" '+%H:%M:%S %Z' 2>/dev/null)
        [[ -n "$wake" ]] && wake=" (until ${wake})"
        echo "[$(date '+%H:%M:%S')] Rate/usage limit hit; waiting ~${secs}s${wake}, then retrying (wait ${limit_waits}/${max_limit_waits})."
        # Wait against the real clock (not a fixed-duration sleep) so a Mac that
        # sleeps mid-wait resumes the moment it wakes instead of freezing.
        marathon_wait_until "$target"
        continue   # do not increment iter — limit waits are free
        ;;
      ERROR*)
        notify "claude-marathon" "Stopped on error: ${verdict#ERROR }"
        echo "ERROR stop: ${verdict#ERROR }. Logs: $logdir"
        return 1
        ;;
      OK)
        : # made progress but not done; keep going
        ;;
    esac
    iter=$((iter + 1))
  done

  notify "claude-marathon" "Stopped: reached max iterations ($max)."
  echo "CAP reached: $max iteration(s) without completion. Logs: $logdir"
  return 2
}

# xml_escape <string> -> XML/plist-safe string (escapes & < > " ')
xml_escape() {
  local s="$1"
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//\"/&quot;}
  s=${s//\'/&apos;}
  printf '%s' "$s"
}

# render_launchd_plist <label> <task> <workdir> <logfile> <script_path> -> plist XML
# Task/workdir are passed via EnvironmentVariables (never shell-interpolated).
# The job runs caffeinate -> claude-marathon, then boots itself out and deletes
# its own plist, so it does NOT re-run on next login/reboot.
render_launchd_plist() {
  local label="$1" task="$2" workdir="$3" logfile="$4" script="$5" resume_id="${6:-}" claude_cmd="${7:-claude}"
  local uid plist
  uid=$(id -u)
  plist="$HOME/Library/LaunchAgents/${label}.plist"

  local e_label e_task e_workdir e_logfile e_script e_plist e_resume e_claude
  e_label=$(xml_escape "$label")
  e_task=$(xml_escape "$task")
  e_workdir=$(xml_escape "$workdir")
  e_logfile=$(xml_escape "$logfile")
  e_script=$(xml_escape "$script")
  e_plist=$(xml_escape "$plist")
  e_resume=$(xml_escape "$resume_id")
  e_claude=$(xml_escape "$claude_cmd")

  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${e_label}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>MARATHON_TASK</key><string>${e_task}</string>
    <key>MARATHON_WORKDIR</key><string>${e_workdir}</string>
    <key>MARATHON_RESUME</key><string>${e_resume}</string>
    <key>MARATHON_CLAUDE_CMD</key><string>${e_claude}</string>
  </dict>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>caffeinate -i "${e_script}" \${MARATHON_RESUME:+--resume "\$MARATHON_RESUME"} "\$MARATHON_TASK" "\$MARATHON_WORKDIR"; rm -f "${e_plist}"; /bin/launchctl bootout gui/${uid}/${e_label} 2>/dev/null</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key><string>${e_logfile}</string>
  <key>StandardErrorPath</key><string>${e_logfile}</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST
}

# parse_queue <file> -> task blocks separated by NUL bytes
# Tasks are separated by a line containing only `---`. Each block is trimmed of
# surrounding whitespace; empty blocks are skipped. Multi-line tasks supported.
parse_queue() {
  awk '
    function flush(   t) {
      t = buf; buf = ""
      sub(/^[[:space:]]+/, "", t)
      sub(/[[:space:]]+$/, "", t)
      if (length(t) > 0) printf "%s%c", t, 0
    }
    /^[[:space:]]*---[[:space:]]*$/ { flush(); next }
    { buf = buf $0 "\n" }
    END { flush() }
  ' "$1"
}

# run_marathon_queue <queue_file> [workdir] [stop_on_fail] -> 0 all done | 1 some failed
# Runs each task as its own fresh isolated marathon (new conversation per task).
# Continues past failures by default; stop_on_fail=1 halts on the first failure.
run_marathon_queue() {
  set +e   # manages its own exit codes; never let a caller's errexit abort it
  local queue_file="$1" workdir="${2:-$PWD}" stop_on_fail="${3:-0}"
  local idx=0 done_n=0 fail_n=0 total=0
  local -a results=()
  local task rc

  while IFS= read -r -d '' task; do
    idx=$((idx + 1))
    echo "===== Queue task ${idx} ====="
    run_marathon "$task" "$workdir"
    rc=$?
    if (( rc == 0 )); then
      done_n=$((done_n + 1)); results+=("task ${idx}: DONE")
    else
      fail_n=$((fail_n + 1)); results+=("task ${idx}: FAILED (rc=${rc})")
      if [[ "$stop_on_fail" == "1" ]]; then
        echo "Stopping queue: task ${idx} failed and --stop-on-fail is set."
        break
      fi
    fi
  done < <(parse_queue "$queue_file")

  total=$((done_n + fail_n))
  if (( total == 0 )); then
    echo "Queue is empty — no tasks found in ${queue_file}."
    notify "claude-marathon queue" "Queue empty: no tasks found."
    return 0
  fi

  echo "===== Queue summary ====="
  local line
  for line in "${results[@]}"; do
    echo "  $line"
  done
  echo "Completed ${done_n}/${total}, failed ${fail_n}."
  notify "claude-marathon queue" "Queue: ${done_n}/${total} done, ${fail_n} failed."
  (( fail_n == 0 ))
}

# render_launchd_queue_plist <label> <queue_file> <workdir> <logfile> <queue_script> [stop_on_fail] [claude_cmd]
# Like render_launchd_plist but runs marathon-queue over a queue file.
render_launchd_queue_plist() {
  local label="$1" queue_file="$2" workdir="$3" logfile="$4" script="$5" stop_on_fail="${6:-}" claude_cmd="${7:-claude}"
  local uid plist
  uid=$(id -u)
  plist="$HOME/Library/LaunchAgents/${label}.plist"

  local e_label e_queue e_workdir e_logfile e_script e_plist e_stop e_claude
  e_label=$(xml_escape "$label")
  e_queue=$(xml_escape "$queue_file")
  e_workdir=$(xml_escape "$workdir")
  e_logfile=$(xml_escape "$logfile")
  e_script=$(xml_escape "$script")
  e_plist=$(xml_escape "$plist")
  e_stop=$(xml_escape "$stop_on_fail")
  e_claude=$(xml_escape "$claude_cmd")

  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${e_label}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>MARATHON_QUEUE</key><string>${e_queue}</string>
    <key>MARATHON_WORKDIR</key><string>${e_workdir}</string>
    <key>MARATHON_STOP_ON_FAIL</key><string>${e_stop}</string>
    <key>MARATHON_CLAUDE_CMD</key><string>${e_claude}</string>
  </dict>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>caffeinate -i "${e_script}" \${MARATHON_STOP_ON_FAIL:+--stop-on-fail} "\$MARATHON_QUEUE" "\$MARATHON_WORKDIR"; rm -f "${e_plist}"; /bin/launchctl bootout gui/${uid}/${e_label} 2>/dev/null</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key><string>${e_logfile}</string>
  <key>StandardErrorPath</key><string>${e_logfile}</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST
}
