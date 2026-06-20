#!/usr/bin/env bash
# marathon-lib.sh — pure functions for claude-marathon.
# Side-effect free on source: defines vars + functions only.

: "${MARATHON_MAX_ITERS:=20}"
: "${MARATHON_TIMEOUT:=7200}"
: "${MARATHON_FALLBACK_SLEEP:=1800}"
: "${MARATHON_BUFFER:=60}"
: "${MARATHON_SENTINEL:=.marathon-done}"
: "${MARATHON_LOG_DIR:=$HOME/.claude/marathon-logs}"
: "${MARATHON_CLAUDE_CMD:=claude}"
: "${MARATHON_SLEEP_CMD:=sleep}"
: "${MARATHON_NOTIFY:=auto}"

marathon_version() {
  echo "claude-marathon 0.1.0"
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
  # (3) phrase present but no machine-readable reset time -> fallback sleep
  if printf '%s' "$raw" | grep -qiE 'usage (limit|credit limit) reached'; then
    echo "LIMIT unknown"
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

# run_marathon <task> [workdir] [resume_id] -> 0 done | 1 error | 2 cap reached
run_marathon() {
  set +e   # the loop classifies non-zero claude exits (limit/error); never let errexit abort it
  local task="$1" workdir="${2:-$PWD}" resume_id="${3:-}"
  local sentinel="${MARATHON_SENTINEL:-.marathon-done}"
  local max="${MARATHON_MAX_ITERS:-20}"
  local buffer="${MARATHON_BUFFER:-60}"
  local fallback="${MARATHON_FALLBACK_SLEEP:-1800}"
  local logdir="${MARATHON_LOG_DIR:-$HOME/.claude/marathon-logs}"
  local sleepcmd="${MARATHON_SLEEP_CMD:-sleep}"

  mkdir -p "$logdir"
  rm -f "$workdir/$sentinel"

  local iter=0
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
        local epoch secs
        epoch=${verdict#LIMIT }
        secs=$(compute_sleep "$epoch" "$(date +%s)" "$buffer" "$fallback")
        echo "Usage limit hit; sleeping ${secs}s until reset (iter $iter)."
        "$sleepcmd" "$secs"
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
    ((iter++))
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
