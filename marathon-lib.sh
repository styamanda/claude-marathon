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

marathon_version() {
  echo "claude-marathon 0.1.0"
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

# run_iteration <iter> <workdir> <task> <outfile> [resume_id] -> claude exit code
# Iteration 0: seed a fresh conversation, OR resume <resume_id> if given.
# Iterations 1+: always --continue the most recent conversation in workdir.
run_iteration() {
  local iter="$1" workdir="$2" task="$3" outfile="$4" resume_id="${5:-}"
  local sentinel="${MARATHON_SENTINEL:-.marathon-done}"
  local instr="When the ENTIRE task is fully complete and verified, your final action must be to create an empty file named '${sentinel}' in this directory. Do not create it until everything is truly finished."

  local -a cmd
  cmd=( "${MARATHON_CLAUDE_CMD:-claude}" -p --output-format json --permission-mode bypassPermissions )
  if (( iter == 0 )); then
    if [[ -n "$resume_id" ]]; then
      cmd+=( --resume "$resume_id" "${task}"$'\n\n'"${instr}" )
    else
      cmd+=( "${task}"$'\n\n'"${instr}" )
    fi
  else
    cmd+=( --continue "Continue the task where you left off. ${instr}" )
  fi

  ( cd "$workdir" && run_with_timeout "${MARATHON_TIMEOUT:-7200}" "${cmd[@]}" ) > "$outfile" 2>&1
  return $?
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
  local sleepcmd="${MARATHON_SLEEP_CMD:-sleep}"

  mkdir -p "$logdir"
  rm -f "$workdir/$sentinel"

  local iter=0 limit_waits=0
  while (( iter < max )); do
    local stamp outfile
    stamp=$(date +%Y%m%d-%H%M%S)
    outfile="$logdir/iter-${iter}-${stamp}.log"

    run_iteration "$iter" "$workdir" "$task" "$outfile" "$resume_id"
    local code=$?

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
        local epoch secs
        epoch=${verdict#LIMIT }
        secs=$(compute_sleep "$epoch" "$(date +%s)" "$buffer" "$fallback")
        echo "Rate/usage limit hit; sleeping ${secs}s, then retrying (wait ${limit_waits}/${max_limit_waits})."
        "$sleepcmd" "$secs"
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
