#!/usr/bin/env bash
# Dependency-free bash test runner for claude-marathon.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../marathon-lib.sh
source "$HERE/../marathon-lib.sh"

# Heartbeat is a wall-clock background pulse; keep it off so loop tests are
# deterministic (a dedicated test below exercises it explicitly).
export MARATHON_HEARTBEAT=0

# The collision guard's real scanner shells out to pgrep+lsof; stub it off by
# default so the suite is fast and deterministic. Specific tests set
# MARATHON_SESSION_PROBE_CMD (or MARATHON_ALLOW_SHARED_DIR) to exercise it.
export MARATHON_SESSION_PROBE_CMD=true

# Pin a simulated clock far in the future so limit-waits in the loop tests return
# instantly (marathon_wait_until polls the real clock; a dedicated test below
# feeds it a controlled clock to verify the sleep-resilient behaviour).
NOW_FAR=$(mktemp); printf '#!/usr/bin/env bash\necho 9999999999\n' > "$NOW_FAR"; chmod +x "$NOW_FAR"
export MARATHON_NOW_CMD="$NOW_FAR"

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    echo "PASS: $name"
    ((PASS++))
  else
    echo "FAIL: $name"
    echo "   got:  $got"
    echo "   want: $want"
    ((FAIL++))
  fi
}

# spawn_detached <pidfile> <cmd...> : run <cmd> as a process REPARENTED to init
# (not a child of this shell), writing its pid to <pidfile>. Because it isn't our
# child, `kill -0` reports it gone cleanly once it exits — no lingering zombie to
# confuse the liveness checks in the trap/stop tests below.
spawn_detached() {
  local pf="$1"; shift
  # Launch via a transient `bash -c` that backgrounds the command and exits at
  # once: the command reparents to init, so the TEST shell never holds it as a
  # job (no async "Terminated" notice when a later test kills it) and kill -0
  # reports it gone cleanly on death (no lingering zombie).
  local q="" a
  for a in "$@"; do printf -v a '%q' "$a"; q+=" $a"; done
  bash -c "$q & echo \$! > $(printf '%q' "$pf")" </dev/null
  local _i
  for ((_i=0; _i<40; _i++)); do [[ -s "$pf" ]] && break; sleep 0.05; done
}

# --- harness self-test ---
assert_eq "$(marathon_version)" "claude-marathon 0.1.0" "marathon_version returns version string"

# --- classify_result ---
assert_eq "$(classify_result "$(cat "$HERE/fixtures/limit.json")" 0)" \
  "LIMIT 1750464000" "classify: legacy pipe format -> LIMIT epoch"
assert_eq "$(classify_result "$(cat "$HERE/fixtures/limit_resetsat.json")" 0)" \
  "LIMIT 1750464000" "classify: resetsAt field (CLI v2.1.x) -> LIMIT epoch"
assert_eq "$(classify_result "$(cat "$HERE/fixtures/limit_text.json")" 0)" \
  "LIMIT unknown" "classify: bare 'usage limit reached' phrase -> LIMIT unknown"
# parse_reset_epoch: human reset times -> epoch for that clock time (verify back)
E1=$(parse_reset_epoch "You've hit your session limit · resets 4:20am (Europe/London)")
assert_eq "$(TZ=Europe/London date -r "$E1" +%H:%M)" "04:20" "parse_reset_epoch: 4:20am London"
E2=$(parse_reset_epoch "resets 8pm (Europe/London)")
assert_eq "$(TZ=Europe/London date -r "$E2" +%H:%M)" "20:00" "parse_reset_epoch: 8pm London"
parse_reset_epoch "no reset time here" >/dev/null; assert_eq "$?" "1" "parse_reset_epoch: no time -> rc 1"

# classify: session limit with a clearly-FUTURE reset -> LIMIT <epoch>
FUT=$(TZ=Europe/London date -v+4H +"%-I:%M%p" 2>/dev/null)
MSG_F="{\"is_error\":true,\"result\":\"You've hit your session limit · resets ${FUT} (Europe/London)\"}"
VF=$(classify_result "$MSG_F" 0)
case "$VF" in "LIMIT "[0-9]*) VFOK=yes;; *) VFOK=no;; esac
assert_eq "$VFOK" "yes" "classify: session-limit w/ future reset -> LIMIT <epoch>"

# classify: limit phrasing with no parseable time -> LIMIT unknown (short-poll path)
assert_eq "$(classify_result "$(cat "$HERE/fixtures/session-limit.json")" 0 | grep -oE '^LIMIT')" \
  "LIMIT" "classify: real session-limit message -> a LIMIT verdict"
assert_eq "$(classify_result "$(cat "$HERE/fixtures/success.json")" 0)" \
  "OK" "classify: clean success -> OK"
assert_eq "$(classify_result "$(cat "$HERE/fixtures/error.json")" 0)" \
  "ERROR Something broke during execution." "classify: is_error true -> ERROR msg"
assert_eq "$(classify_result "$(cat "$HERE/fixtures/malformed.txt")" 0)" \
  "OK" "classify: malformed non-error output -> OK"
assert_eq "$(classify_result "$(cat "$HERE/fixtures/malformed.txt")" 7)" \
  "ERROR exit_code=7" "classify: malformed + nonzero exit -> ERROR"

# --- contains_smart_quotes ---
contains_smart_quotes "“Continue where we left off“"; assert_eq "$?" "0" "smart_quotes: curly double -> detected"
contains_smart_quotes "it’s broken"; assert_eq "$?" "0" "smart_quotes: curly single -> detected"
contains_smart_quotes "\"Refactor the auth module\""; assert_eq "$?" "1" "smart_quotes: straight quotes -> clean"
contains_smart_quotes "plain text no quotes"; assert_eq "$?" "1" "smart_quotes: no quotes -> clean"

# --- entrypoints reject smart quotes with a clear error (exit 64) ---
"$HERE/../marathon-launchd" "“do a thing“" /tmp >/dev/null 2>&1; assert_eq "$?" "64" "launchd: smart quotes -> exit 64"
"$HERE/../claude-marathon" "“do a thing“" /tmp >/dev/null 2>&1; assert_eq "$?" "64" "claude-marathon: smart quotes -> exit 64"

# --- compute_sleep ---
assert_eq "$(compute_sleep 2000 1000 60 1800)" "1060" "sleep: future epoch + buffer"
assert_eq "$(compute_sleep 1000 2000 60 1800)" "0"    "sleep: past epoch clamps to 0"
assert_eq "$(compute_sleep notanumber 2000 60 1800)" "1800" "sleep: bad epoch -> fallback"

# --- run_with_timeout ---
run_with_timeout 5 true; assert_eq "$?" "0"   "timeout: fast success -> 0"
run_with_timeout 5 bash -c 'exit 3'; assert_eq "$?" "3" "timeout: fast failure passes code"
run_with_timeout 1 sleep 4; assert_eq "$?" "124" "timeout: slow command -> 124"

# --- notify ---
assert_eq "$(MARATHON_NOTIFY=off notify "T" "M")" "" "notify: off mode is silent"
assert_eq "$(MARATHON_NOTIFY=echo notify "T" "M")" "[notify] T: M" "notify: echo mode prints"

# --- log discovery / tail helpers ---
LG_TMP=$(mktemp -d)
printf 'old one\n' > "$LG_TMP/old.log"
printf 'new one\nlast new\n' > "$LG_TMP/new.log"
touch -t 202501010101 "$LG_TMP/old.log"
touch -t 202501010202 "$LG_TMP/new.log"
assert_eq "$(MARATHON_LOG_DIR="$LG_TMP" marathon_latest_log)" "$LG_TMP/new.log" \
  "logs: latest log is newest by mtime"
LG_OUT=$(MARATHON_LOG_DIR="$LG_TMP" marathon_logs 1)
case "$LG_OUT" in *"$LG_TMP/new.log"* ) LG_HAS_NEW=yes;; *) LG_HAS_NEW=no;; esac
assert_eq "$LG_HAS_NEW" "yes" "logs: list includes newest log"
case "$LG_OUT" in *"$LG_TMP/old.log"* ) LG_HAS_OLD=yes;; *) LG_HAS_OLD=no;; esac
assert_eq "$LG_HAS_OLD" "no" "logs: limit trims older logs"
TAIL_OUT=$(MARATHON_LOG_DIR="$LG_TMP" MARATHON_TAIL_FOLLOW=0 marathon_tail 1 2>/dev/null)
assert_eq "$TAIL_OUT" "last new" "tail: newest log, last N lines, no-follow mode"
assert_eq "$(MARATHON_LOG_DIR="$LG_TMP/none" marathon_logs)" "(no marathon logs in $LG_TMP/none)" \
  "logs: empty dir prints friendly message"
rm -rf "$LG_TMP"

# --- doctor ---
DOC_TMP=$(mktemp -d)
DOC_OUT=$(MARATHON_CLAUDE_CMD="$HERE/fake-claude.sh" \
  MARATHON_LOG_DIR="$DOC_TMP/logs" MARATHON_LOCK_DIR="$DOC_TMP/locks" \
  marathon_doctor)
DOC_RC=$?
assert_eq "$DOC_RC" "0" "doctor: passes with fake claude and writable dirs"
case "$DOC_OUT" in *"OK"*"claude CLI"* ) DOC_CLAUDE=yes;; *) DOC_CLAUDE=no;; esac
assert_eq "$DOC_CLAUDE" "yes" "doctor: reports claude CLI check"
DOC_BAD=$(MARATHON_CLAUDE_CMD="$DOC_TMP/missing-claude" \
  MARATHON_LOG_DIR="$DOC_TMP/logs" MARATHON_LOCK_DIR="$DOC_TMP/locks" \
  marathon_doctor)
DOC_BAD_RC=$?
assert_eq "$DOC_BAD_RC" "1" "doctor: missing claude fails"
case "$DOC_BAD" in *"FAIL"*"claude CLI"* ) DOC_FAIL=yes;; *) DOC_FAIL=no;; esac
assert_eq "$DOC_FAIL" "yes" "doctor: missing claude reports FAIL"
rm -rf "$DOC_TMP"

# --- run_iteration ---
chmod +x "$HERE/fake-claude.sh"
ITER_TMP=$(mktemp -d)
export FAKE_CLAUDE_OUT="$HERE/fixtures/success.json"
export FAKE_CLAUDE_ARGV="$ITER_TMP/argv.txt"
MARATHON_CLAUDE_CMD="$HERE/fake-claude.sh" \
  run_iteration 0 "$ITER_TMP" "Build the thing" "$ITER_TMP/out0.log" >/dev/null
assert_eq "$?" "0" "iteration: returns underlying exit code"
assert_eq "$(grep -c 'Did some work' "$ITER_TMP/out0.log")" "1" "iteration: writes claude output to logfile"
assert_eq "$(grep -c -- '--continue' "$ITER_TMP/argv.txt")" "0" "iteration 0: seed run has no --continue"

MARATHON_CLAUDE_CMD="$HERE/fake-claude.sh" \
  run_iteration 1 "$ITER_TMP" "Build the thing" "$ITER_TMP/out1.log" >/dev/null
assert_eq "$(grep -c -- '--continue' "$ITER_TMP/argv.txt")" "1" "iteration 1: resume run uses --continue"

# resume id applies on iteration 0
MARATHON_CLAUDE_CMD="$HERE/fake-claude.sh" \
  run_iteration 0 "$ITER_TMP" "Continue" "$ITER_TMP/outr0.log" "sess-abc123" >/dev/null
assert_eq "$(grep -c -- '--resume sess-abc123' "$ITER_TMP/argv.txt")" "1" "iteration 0 + resume id: uses --resume <id>"
assert_eq "$(grep -c -- '--continue' "$ITER_TMP/argv.txt")" "0" "iteration 0 + resume id: no --continue"

# resume id ignored on iteration 1 (still --continue)
MARATHON_CLAUDE_CMD="$HERE/fake-claude.sh" \
  run_iteration 1 "$ITER_TMP" "Continue" "$ITER_TMP/outr1.log" "sess-abc123" >/dev/null
assert_eq "$(grep -c -- '--resume' "$ITER_TMP/argv.txt")" "0" "iteration 1 + resume id: no --resume"
assert_eq "$(grep -c -- '--continue' "$ITER_TMP/argv.txt")" "1" "iteration 1 + resume id: uses --continue"

unset FAKE_CLAUDE_OUT FAKE_CLAUDE_ARGV
rm -rf "$ITER_TMP"

# --- marathon_format_stream (live narration + result capture) ---
FS_TMP=$(mktemp -d)
FS_OUT=$(marathon_format_stream "$FS_TMP/result.json" < "$HERE/fixtures/stream.jsonl")
assert_eq "$(grep -c '"type":"result"' "$FS_TMP/result.json")" "1" \
  "format_stream: captures exactly the result event to outfile"
assert_eq "$(classify_result "$(cat "$FS_TMP/result.json")" 0)" "OK" \
  "format_stream: captured result still classifies (OK)"
assert_eq "$(printf '%s\n' "$FS_OUT" | grep -c 'claude: Running the tests.')" "1" \
  "format_stream: narrates assistant text to the live log"
assert_eq "$(printf '%s\n' "$FS_OUT" | grep -c 'Bash:')" "1" \
  "format_stream: narrates each tool call"
# non-JSON passes through; a bare object (no .type) is captured via the fallback
FS_OUT2=$(printf '%s\n' 'boom: crashed' '{"is_error":false,"result":"bare ok"}' \
          | marathon_format_stream "$FS_TMP/result2.json")
assert_eq "$(printf '%s\n' "$FS_OUT2" | grep -c 'boom: crashed')" "1" \
  "format_stream: passes non-JSON lines through verbatim"
assert_eq "$(grep -c 'bare ok' "$FS_TMP/result2.json")" "1" \
  "format_stream: falls back to the last bare JSON object as the result"
rm -rf "$FS_TMP"

# --- run_marathon: limit, limit, then done via sentinel ---
LOOP_TMP=$(mktemp -d)
mkdir -p "$LOOP_TMP/logs"
cat > "$LOOP_TMP/fake.sh" <<'EOF'
#!/usr/bin/env bash
N_FILE="$LOOP_TMP/n"
n=$(cat "$N_FILE" 2>/dev/null || echo 0)
n=$((n+1)); echo "$n" > "$N_FILE"
if (( n < 3 )); then
  echo '{"is_error":true,"result":"Claude AI usage limit reached|1"}'
else
  : > "$LOOP_TMP/work/.marathon-done"
  echo '{"is_error":false,"result":"done"}'
fi
EOF
sed -i.bak "s#\$LOOP_TMP#$LOOP_TMP#g" "$LOOP_TMP/fake.sh"
chmod +x "$LOOP_TMP/fake.sh"
mkdir -p "$LOOP_TMP/work"

OUT=$(MARATHON_CLAUDE_CMD="$LOOP_TMP/fake.sh" \
      MARATHON_SLEEP_CMD=true \
      MARATHON_NOTIFY=off \
      MARATHON_LOG_DIR="$LOOP_TMP/logs" \
      MARATHON_MAX_ITERS=10 \
      run_marathon "do work" "$LOOP_TMP/work")
RC=$?
assert_eq "$RC" "0" "marathon: completes via sentinel after limits"
assert_eq "$(echo "$OUT" | grep -c 'DONE')" "1" "marathon: reports DONE"
assert_eq "$(cat "$LOOP_TMP/n")" "3" "marathon: ran exactly 3 iterations"

# --- run_marathon: cap reached (sentinel never appears) ---
CAP_TMP=$(mktemp -d); mkdir -p "$CAP_TMP/work" "$CAP_TMP/logs"
OUT2=$(MARATHON_CLAUDE_CMD="$HERE/fake-claude.sh" \
       FAKE_CLAUDE_OUT="$HERE/fixtures/success.json" \
       MARATHON_SLEEP_CMD=true MARATHON_NOTIFY=off \
       MARATHON_LOG_DIR="$CAP_TMP/logs" MARATHON_MAX_ITERS=3 \
       run_marathon "never done" "$CAP_TMP/work"); RC2=$?
assert_eq "$RC2" "2" "marathon: returns 2 when cap reached"
assert_eq "$(echo "$OUT2" | grep -c 'CAP')" "1" "marathon: reports CAP"

# --- run_marathon: hard error stops loop ---
ERR_TMP=$(mktemp -d); mkdir -p "$ERR_TMP/work" "$ERR_TMP/logs"
OUT3=$(MARATHON_CLAUDE_CMD="$HERE/fake-claude.sh" \
       FAKE_CLAUDE_OUT="$HERE/fixtures/error.json" \
       MARATHON_SLEEP_CMD=true MARATHON_NOTIFY=off \
       MARATHON_LOG_DIR="$ERR_TMP/logs" MARATHON_MAX_ITERS=10 \
       run_marathon "broken" "$ERR_TMP/work"); RC3=$?
assert_eq "$RC3" "1" "marathon: returns 1 on hard error"

# --- run_marathon: limit waits do NOT consume the productive iteration budget ---
LW_TMP=$(mktemp -d); mkdir -p "$LW_TMP/work" "$LW_TMP/logs"
cat > "$LW_TMP/fake.sh" <<'EOF'
#!/usr/bin/env bash
N_FILE="LWDIR/n"
n=$(cat "$N_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$N_FILE"
if (( n <= 4 )); then
  echo '{"is_error":true,"result":"You'"'"'ve hit your session limit · resets 8pm (Europe/London)"}'
else
  : > "LWDIR/work/.marathon-done"; echo '{"is_error":false,"result":"done"}'
fi
EOF
sed -i.bak "s#LWDIR#$LW_TMP#g" "$LW_TMP/fake.sh"; chmod +x "$LW_TMP/fake.sh"
LW_OUT=$(MARATHON_CLAUDE_CMD="$LW_TMP/fake.sh" MARATHON_SLEEP_CMD=true MARATHON_NOTIFY=off \
  MARATHON_LOG_DIR="$LW_TMP/logs" MARATHON_MAX_ITERS=2 MARATHON_MAX_LIMIT_WAITS=10 \
  run_marathon "x" "$LW_TMP/work"); LW_RC=$?
assert_eq "$LW_RC" "0" "marathon: completes despite 4 limit waits under MAX_ITERS=2 (waits are free)"
assert_eq "$(cat "$LW_TMP/n")" "5" "marathon: ran all 5 claude calls (4 limits + 1 done)"
rm -rf "$LW_TMP"

# --- run_marathon: prints a start line + heartbeat so the log isn't "frozen" ---
HB_TMP=$(mktemp -d); mkdir -p "$HB_TMP/work" "$HB_TMP/logs"
cat > "$HB_TMP/fake.sh" <<EOF
#!/usr/bin/env bash
sleep 2
: > "$HB_TMP/work/.marathon-done"
echo '{"is_error":false,"result":"done"}'
EOF
chmod +x "$HB_TMP/fake.sh"
HB_OUT=$(MARATHON_CLAUDE_CMD="$HB_TMP/fake.sh" MARATHON_SLEEP_CMD=true MARATHON_NOTIFY=off \
  MARATHON_LOG_DIR="$HB_TMP/logs" MARATHON_MAX_ITERS=2 MARATHON_HEARTBEAT=1 \
  run_marathon "x" "$HB_TMP/work")
assert_eq "$(echo "$HB_OUT" | grep -c 'iteration 1/2: claude is working')" "1" "marathon: prints iteration start line"
case "$(echo "$HB_OUT" | grep -c 'still working')" in 0) HBP=no;; *) HBP=yes;; esac
assert_eq "$HBP" "yes" "marathon: heartbeat pulses during a slow iteration"
rm -rf "$HB_TMP"

# --- run_marathon: limit sleep line shows the absolute wake time ---
WK_TMP=$(mktemp -d); mkdir -p "$WK_TMP/work" "$WK_TMP/logs"
cat > "$WK_TMP/fake.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"is_error":true,"result":"You'"'"'ve hit your session limit · resets 8pm"}'
EOF
chmod +x "$WK_TMP/fake.sh"
WK_OUT=$(MARATHON_CLAUDE_CMD="$WK_TMP/fake.sh" MARATHON_SLEEP_CMD=true MARATHON_NOTIFY=off \
  MARATHON_LOG_DIR="$WK_TMP/logs" MARATHON_MAX_ITERS=2 MARATHON_MAX_LIMIT_WAITS=1 \
  run_marathon "x" "$WK_TMP/work")
assert_eq "$(echo "$WK_OUT" | grep -c 'waiting ~.*s (until ')" "1" "marathon: limit line shows absolute wake time"
rm -rf "$WK_TMP"

# --- run_marathon: gives up (rc 3) if rate-limited beyond MAX_LIMIT_WAITS ---
PL_TMP=$(mktemp -d); mkdir -p "$PL_TMP/work" "$PL_TMP/logs"
cat > "$PL_TMP/fake.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"is_error":true,"result":"You'"'"'ve hit your session limit · resets 8pm"}'
EOF
chmod +x "$PL_TMP/fake.sh"
PL_OUT=$(MARATHON_CLAUDE_CMD="$PL_TMP/fake.sh" MARATHON_SLEEP_CMD=true MARATHON_NOTIFY=off \
  MARATHON_LOG_DIR="$PL_TMP/logs" MARATHON_MAX_ITERS=5 MARATHON_MAX_LIMIT_WAITS=2 \
  run_marathon "x" "$PL_TMP/work"); PL_RC=$?
assert_eq "$PL_RC" "3" "marathon: persistent limit -> rc 3 (gave up)"
assert_eq "$(echo "$PL_OUT" | grep -c 'GAVE UP')" "1" "marathon: persistent limit prints GAVE UP"
rm -rf "$PL_TMP"

# --- run_marathon: survives a caller's set -e when claude exits non-zero ---
# Regression: launchd job used `set -e`, so a failing/limit claude aborted the
# loop instead of being classified. run_marathon must neutralize errexit itself.
SETE_TMP=$(mktemp -d); mkdir -p "$SETE_TMP/work" "$SETE_TMP/logs"
cat > "$SETE_TMP/fake.sh" <<'EOF'
#!/usr/bin/env bash
echo "claude: command not found" >&2
exit 127
EOF
chmod +x "$SETE_TMP/fake.sh"
SETE_OUT=$( set -e
  MARATHON_CLAUDE_CMD="$SETE_TMP/fake.sh" MARATHON_SLEEP_CMD=true MARATHON_NOTIFY=off \
  MARATHON_LOG_DIR="$SETE_TMP/logs" MARATHON_MAX_ITERS=3 \
  run_marathon "x" "$SETE_TMP/work" ); SETE_RC=$?
assert_eq "$SETE_RC" "1" "marathon: under caller set -e, failing claude -> rc=1 (not aborted)"
assert_eq "$(echo "$SETE_OUT" | grep -c 'ERROR stop')" "1" "marathon: under set -e, loop ran and printed ERROR stop"
rm -rf "$SETE_TMP"

rm -rf "$LOOP_TMP" "$CAP_TMP" "$ERR_TMP"

# --- parse_queue ---
QF="$HERE/fixtures/queue-sample.txt"
assert_eq "$(parse_queue "$QF" | tr -cd '\0' | wc -c | tr -d ' ')" "3" "parse_queue: 3 tasks from sample"
T2=$(parse_queue "$QF" | { i=0; while IFS= read -r -d '' t; do i=$((i+1)); [[ $i -eq 2 ]] && printf '%s' "$t"; done; })
assert_eq "$T2" "$(printf 'Task two\nhas two lines')" "parse_queue: multi-line task preserved"

# --- run_marathon_queue ---
QTMP=$(mktemp -d); mkdir -p "$QTMP/work" "$QTMP/logs"
cat > "$QTMP/fake.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *GOOD*) : > .marathon-done; echo '{"is_error":false,"result":"ok"}' ;;
  *)      echo '{"is_error":true,"result":"deliberate failure"}' ;;
esac
EOF
chmod +x "$QTMP/fake.sh"

printf 'GOOD first\n---\nGOOD second\n' > "$QTMP/all-good.txt"
QOUT=$(MARATHON_CLAUDE_CMD="$QTMP/fake.sh" MARATHON_SLEEP_CMD=true MARATHON_NOTIFY=off \
  MARATHON_LOG_DIR="$QTMP/logs" MARATHON_MAX_ITERS=3 \
  run_marathon_queue "$QTMP/all-good.txt" "$QTMP/work"); QRC=$?
assert_eq "$QRC" "0" "queue: all-good -> rc 0"
assert_eq "$(echo "$QOUT" | grep -cE 'task [0-9]+: DONE')" "2" "queue: both tasks DONE"

printf 'BAD one\n---\nGOOD two\n' > "$QTMP/mixed.txt"
QOUT2=$(MARATHON_CLAUDE_CMD="$QTMP/fake.sh" MARATHON_SLEEP_CMD=true MARATHON_NOTIFY=off \
  MARATHON_LOG_DIR="$QTMP/logs" MARATHON_MAX_ITERS=3 \
  run_marathon_queue "$QTMP/mixed.txt" "$QTMP/work"); QRC2=$?
assert_eq "$QRC2" "1" "queue: a failure makes overall rc nonzero"
assert_eq "$(echo "$QOUT2" | grep -c 'FAILED')" "1" "queue: continues past failure (1 failed)"
assert_eq "$(echo "$QOUT2" | grep -c 'task 2: DONE')" "1" "queue: ran task 2 after task 1 failed"

QOUT3=$(MARATHON_CLAUDE_CMD="$QTMP/fake.sh" MARATHON_SLEEP_CMD=true MARATHON_NOTIFY=off \
  MARATHON_LOG_DIR="$QTMP/logs" MARATHON_MAX_ITERS=3 \
  run_marathon_queue "$QTMP/mixed.txt" "$QTMP/work" 1); QRC3=$?
assert_eq "$QRC3" "1" "queue: stop-on-fail -> rc 1"
assert_eq "$(echo "$QOUT3" | grep -c 'Queue task 2')" "0" "queue: stop-on-fail did not start task 2"
rm -rf "$QTMP"

# --- render_launchd_queue_plist ---
QP_TMP=$(mktemp -d)
render_launchd_queue_plist "com.test.q" "/tmp/tasks.txt" "/tmp/work" "$QP_TMP/q.log" \
  "$HERE/../marathon-queue" "1" "/abs/bin/claude" > "$QP_TMP/q.plist"
plutil -lint "$QP_TMP/q.plist" >/dev/null 2>&1
assert_eq "$?" "0" "render-queue: plist passes plutil -lint"
assert_eq "$(plutil -extract EnvironmentVariables.MARATHON_QUEUE raw "$QP_TMP/q.plist" 2>/dev/null)" \
  "/tmp/tasks.txt" "render-queue: MARATHON_QUEUE set"
assert_eq "$(plutil -extract EnvironmentVariables.MARATHON_CLAUDE_CMD raw "$QP_TMP/q.plist" 2>/dev/null)" \
  "/abs/bin/claude" "render-queue: claude cmd set"
rm -rf "$QP_TMP"

# --- marathon-queue entrypoint ---
QBIN="$HERE/../marathon-queue"
chmod +x "$QBIN" 2>/dev/null || true
"$QBIN" >/dev/null 2>&1; assert_eq "$?" "64" "marathon-queue: no args -> 64"
"$QBIN" /nonexistent/queue/file >/dev/null 2>&1; assert_eq "$?" "66" "marathon-queue: missing file -> 66"
assert_eq "$("$QBIN" --version)" "claude-marathon 0.1.0" "marathon-queue: --version"
"$QBIN" --help >/dev/null 2>&1; assert_eq "$?" "0" "marathon-queue: --help -> rc 0"

# --- entrypoint ---
BIN="$HERE/../claude-marathon"
chmod +x "$BIN" 2>/dev/null || true
"$BIN" >/dev/null 2>&1; assert_eq "$?" "64" "entrypoint: no args -> usage exit 64"
assert_eq "$("$BIN" --version)" "claude-marathon 0.1.0" "entrypoint: --version prints version"
"$BIN" --help >/dev/null 2>&1; assert_eq "$?" "0" "entrypoint: --help -> rc 0"
"$BIN" --resume >/dev/null 2>&1; assert_eq "$?" "64" "entrypoint: --resume without id -> exit 64"
"$BIN" --demo >/dev/null 2>&1; assert_eq "$?" "0" "entrypoint: --demo completes synthetic run"

# --- entrypoint via symlink (finds lib through resolved path) ---
LINK_TMP=$(mktemp -d)
ln -s "$BIN" "$LINK_TMP/claude-marathon"
assert_eq "$("$LINK_TMP/claude-marathon" --version)" "claude-marathon 0.1.0" \
  "entrypoint: works when invoked via symlink"
rm -rf "$LINK_TMP"

# --- xml_escape ---
assert_eq "$(xml_escape 'a&b<c>d"e'\''f')" "a&amp;b&lt;c&gt;d&quot;e&apos;f" "xml_escape: escapes & < > \" '"

# --- render_launchd_plist: valid plist even with special chars in task ---
PLIST_TMP=$(mktemp -d)
render_launchd_plist "com.test.marathon" 'Fix A & B <urgent>' "/tmp/work" \
  "$PLIST_TMP/run.log" "$HERE/../claude-marathon" > "$PLIST_TMP/test.plist"
plutil -lint "$PLIST_TMP/test.plist" >/dev/null 2>&1
assert_eq "$?" "0" "render: produced plist passes plutil -lint"
assert_eq "$(plutil -extract Label raw "$PLIST_TMP/test.plist" 2>/dev/null)" \
  "com.test.marathon" "render: Label set correctly"
assert_eq "$(plutil -extract EnvironmentVariables.MARATHON_TASK raw "$PLIST_TMP/test.plist" 2>/dev/null)" \
  "Fix A & B <urgent>" "render: task round-trips through plist unescaped"

# render with a resume id
render_launchd_plist "com.test.resume" "Continue work" "/tmp/work" \
  "$PLIST_TMP/r.log" "$HERE/../claude-marathon" "sess-xyz789" > "$PLIST_TMP/r.plist"
plutil -lint "$PLIST_TMP/r.plist" >/dev/null 2>&1
assert_eq "$?" "0" "render: plist with resume id passes plutil -lint"
assert_eq "$(plutil -extract EnvironmentVariables.MARATHON_RESUME raw "$PLIST_TMP/r.plist" 2>/dev/null)" \
  "sess-xyz789" "render: MARATHON_RESUME set from resume id"

# render bakes an explicit claude command path (PATH-independence for launchd)
assert_eq "$(plutil -extract EnvironmentVariables.MARATHON_CLAUDE_CMD raw "$PLIST_TMP/test.plist" 2>/dev/null)" \
  "claude" "render: MARATHON_CLAUDE_CMD defaults to 'claude'"
render_launchd_plist "com.test.cc" "t" "/tmp" "$PLIST_TMP/cc.log" "/x/claude-marathon" "" "/abs/bin/claude" \
  > "$PLIST_TMP/cc.plist"
assert_eq "$(plutil -extract EnvironmentVariables.MARATHON_CLAUDE_CMD raw "$PLIST_TMP/cc.plist" 2>/dev/null)" \
  "/abs/bin/claude" "render: MARATHON_CLAUDE_CMD set from arg"

# self-cleanup must delete the plist BEFORE bootout (bootout kills its own shell)
ORD_LINE=$(render_launchd_plist "com.test.ord" "t" "/tmp" "/tmp/o.log" "/x/cm" | grep 'caffeinate')
ORD_RM=$(awk -v s="$ORD_LINE" 'BEGIN{print index(s,"rm -f")}')
ORD_BO=$(awk -v s="$ORD_LINE" 'BEGIN{print index(s,"bootout")}')
case "$(( ORD_RM>0 && ORD_BO>0 && ORD_RM<ORD_BO ))" in
  1) ORD=ok;; *) ORD=bad;;
esac
assert_eq "$ORD" "ok" "render: plist self-deletes BEFORE bootout (no reboot re-run)"
rm -rf "$PLIST_TMP"

# --- marathon-launchd --dry-run: writes a lint-clean plist, does not load ---
LAUNCHD_BIN="$HERE/../marathon-launchd"
chmod +x "$LAUNCHD_BIN" 2>/dev/null || true
"$LAUNCHD_BIN" >/dev/null 2>&1; assert_eq "$?" "64" "marathon-launchd: no args -> usage exit 64"
"$LAUNCHD_BIN" --help >/dev/null 2>&1; assert_eq "$?" "0" "marathon-launchd: --help -> rc 0"
assert_eq "$("$LAUNCHD_BIN" --version)" "claude-marathon 0.1.0" "marathon-launchd: --version"
LD_TMP=$(mktemp -d)
mkdir -p "$LD_TMP/home/Library/LaunchAgents" "$LD_TMP/work"
printf 'queued task\n' > "$LD_TMP/tasks.txt"
HOME="$LD_TMP/home" render_launchd_plist "com.claude-marathon.test" \
  "Do a task that has enough detail to show in the list output" "$LD_TMP/work" \
  "$LD_TMP/test.log" "$HERE/../claude-marathon" > "$LD_TMP/home/Library/LaunchAgents/com.claude-marathon.test.plist"
HOME="$LD_TMP/home" render_launchd_queue_plist "com.claude-marathon.exited" \
  "$LD_TMP/tasks.txt" "$LD_TMP/work" "$LD_TMP/exited.log" "$HERE/../marathon-queue" \
  > "$LD_TMP/home/Library/LaunchAgents/com.claude-marathon.exited.plist"
cat > "$LD_TMP/launchctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    cat <<'ROWS'
PID	Status	Label
123	0	com.claude-marathon.test
-	78	com.claude-marathon.exited
999	0	com.example.other
ROWS
    ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$LD_TMP/launchctl"
LD_OUT=$(HOME="$LD_TMP/home" MARATHON_LAUNCHCTL_CMD="$LD_TMP/launchctl" MARATHON_GUI_UID=501 marathon_launchd_jobs)
case "$LD_OUT" in *"RUNNING pid=123 status=0"*"com.claude-marathon.test"*) LD_RUNNING=yes;; *) LD_RUNNING=no;; esac
assert_eq "$LD_RUNNING" "yes" "launchd-list: reports running marathon label"
case "$LD_OUT" in *"EXITED  status=78"*"com.claude-marathon.exited"*) LD_EXITED=yes;; *) LD_EXITED=no;; esac
assert_eq "$LD_EXITED" "yes" "launchd-list: reports exited marathon label"
case "$LD_OUT" in *"workdir: $LD_TMP/work"*) LD_WD=yes;; *) LD_WD=no;; esac
assert_eq "$LD_WD" "yes" "launchd-list: includes workdir from plist"
case "$LD_OUT" in *"queue:   $LD_TMP/tasks.txt"*) LD_QUEUE=yes;; *) LD_QUEUE=no;; esac
assert_eq "$LD_QUEUE" "yes" "launchd-list: includes queue file from plist"
case "$LD_OUT" in *"stop:    launchctl bootout gui/501/com.claude-marathon.test"*) LD_STOP=yes;; *) LD_STOP=no;; esac
assert_eq "$LD_STOP" "yes" "launchd-list: prints exact bootout command"
LD_CLI=$(HOME="$LD_TMP/home" MARATHON_LAUNCHCTL_CMD="$LD_TMP/launchctl" MARATHON_GUI_UID=501 "$LAUNCHD_BIN" --list)
case "$LD_CLI" in *"com.claude-marathon.test"*) LD_CLI_OK=yes;; *) LD_CLI_OK=no;; esac
assert_eq "$LD_CLI_OK" "yes" "marathon-launchd: --list prints launchd jobs"
cat > "$LD_TMP/launchctl-none" <<'EOF'
#!/usr/bin/env bash
echo 'PID	Status	Label'
EOF
chmod +x "$LD_TMP/launchctl-none"
assert_eq "$(MARATHON_LAUNCHCTL_CMD="$LD_TMP/launchctl-none" marathon_launchd_jobs)" \
  "(no launchd marathon jobs)" "launchd-list: empty launchctl list is friendly"
assert_eq "$(MARATHON_LAUNCHCTL_CMD="$LD_TMP/missing" marathon_launchd_jobs)" \
  "(launchd unavailable: launchctl not found)" "launchd-list: missing launchctl is friendly"
rm -rf "$LD_TMP"
DRY_TMP=$(mktemp -d)
DRY_OUT=$(HOME="$DRY_TMP/home" MARATHON_LOG_DIR="$DRY_TMP/logs" "$LAUNCHD_BIN" --dry-run "test task" "$DRY_TMP")
assert_eq "$?" "0" "marathon-launchd: --dry-run exits 0"
DRY_PLIST=$(echo "$DRY_OUT" | sed -n 's/^Wrote (dry-run): //p')
plutil -lint "$DRY_PLIST" >/dev/null 2>&1
assert_eq "$?" "0" "marathon-launchd: --dry-run plist passes plutil -lint"
DRY_CC=$(plutil -extract EnvironmentVariables.MARATHON_CLAUDE_CMD raw "$DRY_PLIST" 2>/dev/null)
case "$DRY_CC" in /*) DRY_ABS=yes;; *) DRY_ABS=no;; esac
assert_eq "$DRY_ABS" "yes" "marathon-launchd: bakes absolute claude path (PATH-independent)"
rm -f "$DRY_PLIST"; rm -rf "$DRY_TMP"

# marathon-launchd queue mode --dry-run
LQ_TMP=$(mktemp -d); printf 'a\n---\nb\n' > "$LQ_TMP/q.txt"
LQ_OUT=$(HOME="$LQ_TMP/home" MARATHON_LOG_DIR="$LQ_TMP/logs" "$LAUNCHD_BIN" --dry-run --queue "$LQ_TMP/q.txt" "$LQ_TMP")
assert_eq "$?" "0" "marathon-launchd: --queue --dry-run exits 0"
LQ_PLIST=$(echo "$LQ_OUT" | sed -n 's/^Wrote (dry-run): //p')
plutil -lint "$LQ_PLIST" >/dev/null 2>&1
assert_eq "$?" "0" "marathon-launchd: --queue plist passes plutil -lint"
LQ_Q=$(plutil -extract EnvironmentVariables.MARATHON_QUEUE raw "$LQ_PLIST" 2>/dev/null)
case "$LQ_Q" in */q.txt) QOK=yes;; *) QOK=no;; esac
assert_eq "$QOK" "yes" "marathon-launchd: --queue sets MARATHON_QUEUE to the file"
rm -f "$LQ_PLIST"; rm -rf "$LQ_TMP"

# --- workdir locking (one marathon per directory) ---
LK_DIR=$(mktemp -d); LK_WD=$(mktemp -d)
export MARATHON_LOCK_DIR="$LK_DIR"
acquire_lock "$LK_WD"; assert_eq "$?" "0" "lock: acquire succeeds when free"
lock_held "$LK_WD"; assert_eq "$?" "0" "lock: held after acquire"
acquire_lock "$LK_WD"; assert_eq "$?" "1" "lock: second acquire (live holder) refused"
release_lock "$LK_WD"; lock_held "$LK_WD"; assert_eq "$?" "1" "lock: released -> not held"
LK_LP=$(marathon_lock_path "$LK_WD"); mkdir -p "$LK_LP"; echo 999999 > "$LK_LP/pid"
acquire_lock "$LK_WD"; assert_eq "$?" "0" "lock: stale lock (dead pid) reclaimed"
release_lock "$LK_WD"
unset MARATHON_LOCK_DIR
rm -rf "$LK_DIR" "$LK_WD"

# entrypoints refuse when the workdir lock is held by another live process
EL_DIR=$(mktemp -d); EL_WD=$(mktemp -d); EL_PF=$(mktemp)
spawn_detached "$EL_PF" sleep 60; EL_BG=$(cat "$EL_PF")
EL_LP=$(MARATHON_LOCK_DIR="$EL_DIR" marathon_lock_path "$EL_WD"); mkdir -p "$EL_LP"; echo "$EL_BG" > "$EL_LP/pid"
MARATHON_LOCK_DIR="$EL_DIR" MARATHON_CLAUDE_CMD="$HERE/fake-claude.sh" "$BIN" "do x" "$EL_WD" >/dev/null 2>&1
assert_eq "$?" "65" "claude-marathon: refuses (exit 65) when workdir lock held"
MARATHON_LOCK_DIR="$EL_DIR" "$LAUNCHD_BIN" "do x" "$EL_WD" >/dev/null 2>&1
assert_eq "$?" "65" "marathon-launchd: refuses (exit 65) when workdir lock held"
kill "$EL_BG" 2>/dev/null
rm -rf "$EL_DIR" "$EL_WD" "$EL_PF"

# --- trap: stopping a running marathon ACTUALLY terminates it (no orphan) ---
# Regression: a bare `trap '…' TERM` released the lock but RESUMED the loop, so
# kill / launchctl bootout left an orphan AND freed the lock for a pile-up.
TRAP_LOCKS=$(mktemp -d); TRAP_WD=$(mktemp -d); TRAP_PF=$(mktemp)
cat > "$TRAP_WD/loop.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$HERE/../marathon-lib.sh"
export MARATHON_LOCK_DIR="$TRAP_LOCKS"
acquire_lock "$TRAP_WD"
install_cleanup_traps "$TRAP_WD"
while true; do sleep 0.2; done
EOF
chmod +x "$TRAP_WD/loop.sh"
spawn_detached "$TRAP_PF" "$TRAP_WD/loop.sh"
TRAP_PID=$(cat "$TRAP_PF")
for ((_i=0; _i<60; _i++)); do MARATHON_LOCK_DIR="$TRAP_LOCKS" lock_held "$TRAP_WD" && break; sleep 0.05; done
MARATHON_LOCK_DIR="$TRAP_LOCKS" lock_held "$TRAP_WD"; assert_eq "$?" "0" "trap: marathon holds its lock while running"
kill -TERM "$TRAP_PID" 2>/dev/null
for ((_i=0; _i<60; _i++)); do kill -0 "$TRAP_PID" 2>/dev/null || break; sleep 0.05; done
kill -0 "$TRAP_PID" 2>/dev/null; assert_eq "$?" "1" "trap: SIGTERM actually terminates the loop (no orphan)"
MARATHON_LOCK_DIR="$TRAP_LOCKS" lock_held "$TRAP_WD"; assert_eq "$?" "1" "trap: lock released after stop"
rm -rf "$TRAP_LOCKS" "$TRAP_WD" "$TRAP_PF"

# --- marathon_status / marathon_stop ---
ST_DIR=$(mktemp -d)
assert_eq "$(MARATHON_LOCK_DIR="$ST_DIR" marathon_status)" "(no marathons running)" "status: empty -> none"
ST_WD1=$(mktemp -d); ST_WD2=$(mktemp -d); ST_PF=$(mktemp)
spawn_detached "$ST_PF" sleep 60
ST_LIVE=$(cat "$ST_PF")
L1=$(MARATHON_LOCK_DIR="$ST_DIR" marathon_lock_path "$ST_WD1"); mkdir -p "$L1"; echo "$ST_LIVE" > "$L1/pid"; echo "$ST_WD1" > "$L1/workdir"
L2=$(MARATHON_LOCK_DIR="$ST_DIR" marathon_lock_path "$ST_WD2"); mkdir -p "$L2"; echo 999999 > "$L2/pid"; echo "$ST_WD2" > "$L2/workdir"
ST_OUT=$(MARATHON_LOCK_DIR="$ST_DIR" marathon_status)
assert_eq "$(echo "$ST_OUT" | grep -c RUNNING)" "1" "status: live marathon reported RUNNING"
assert_eq "$(echo "$ST_OUT" | grep -c STALE)"   "1" "status: dead marathon reported STALE"
case "$ST_OUT" in *"$ST_WD1"*) SWD=yes;; *) SWD=no;; esac
assert_eq "$SWD" "yes" "status: shows the workdir"
MARATHON_LOCK_DIR="$ST_DIR" marathon_stop "$ST_WD2" >/dev/null; assert_eq "$?" "0" "stop: stale lock -> rc 0"
[[ -d "$L2" ]] && SL2=yes || SL2=no; assert_eq "$SL2" "no" "stop: stale lock removed"
MARATHON_LOCK_DIR="$ST_DIR" marathon_stop "$ST_WD1" >/dev/null; assert_eq "$?" "0" "stop: live marathon -> rc 0"
for ((_i=0; _i<60; _i++)); do kill -0 "$ST_LIVE" 2>/dev/null || break; sleep 0.05; done
kill -0 "$ST_LIVE" 2>/dev/null; assert_eq "$?" "1" "stop: live process actually terminated"
[[ -d "$L1" ]] && SL1=yes || SL1=no; assert_eq "$SL1" "no" "stop: live lock removed"
MARATHON_LOCK_DIR="$ST_DIR" marathon_stop "$ST_WD1" >/dev/null; assert_eq "$?" "1" "stop: nothing running -> rc 1"
rm -rf "$ST_DIR" "$ST_WD1" "$ST_WD2" "$ST_PF"

# --- detect_dir_collision (startup guard against VS Code / interactive sessions) ---
CD_PROBE=$(mktemp)
cat > "$CD_PROBE" <<'EOF'
#!/usr/bin/env bash
echo 4242   # pretend a live Claude session has this cwd
EOF
chmod +x "$CD_PROBE"
assert_eq "$(MARATHON_SESSION_PROBE_CMD="$CD_PROBE" detect_dir_collision /some/dir)" "4242" \
  "collision: probe reports a live session in the dir"
assert_eq "$(MARATHON_ALLOW_SHARED_DIR=1 MARATHON_SESSION_PROBE_CMD="$CD_PROBE" detect_dir_collision /some/dir)" "" \
  "collision: MARATHON_ALLOW_SHARED_DIR=1 overrides the guard"
assert_eq "$(claude_sessions_in_dir "$(mktemp -d)")" "" \
  "collision: real scanner finds no session in a fresh temp dir"
# entrypoint refuses (65) when a Claude session is already active in the workdir
CE_LOCK=$(mktemp -d); CE_WD=$(mktemp -d)
MARATHON_LOCK_DIR="$CE_LOCK" MARATHON_SESSION_PROBE_CMD="$CD_PROBE" \
  MARATHON_CLAUDE_CMD="$HERE/fake-claude.sh" "$BIN" "do x" "$CE_WD" >/dev/null 2>&1
assert_eq "$?" "65" "claude-marathon: refuses (65) when another Claude session is active in workdir"
rm -rf "$CE_LOCK" "$CE_WD"; rm -f "$CD_PROBE"

# --- marathon_wait_until: resilient to a clock jump (system sleep) ---
WU_CTR=$(mktemp); echo 0 > "$WU_CTR"; WU_NOW=$(mktemp)
cat > "$WU_NOW" <<EOF
#!/usr/bin/env bash
i=\$(cat "$WU_CTR"); i=\$((i+1)); echo "\$i" > "$WU_CTR"
case "\$i" in
  1) echo 1000000 ;;   # start
  2) echo 1000030 ;;   # 30s later, still waiting
  *) echo 1100000 ;;   # big jump: Mac woke from a long sleep, now past target
esac
EOF
chmod +x "$WU_NOW"
MARATHON_NOW_CMD="$WU_NOW" MARATHON_SLEEP_CMD=true MARATHON_HEARTBEAT=0 MARATHON_WAIT_POLL=60 \
  marathon_wait_until 1003600
assert_eq "$?" "0" "wait_until: returns after the clock jumps past target (sleep-resilient)"
assert_eq "$(cat "$WU_CTR")" "3" "wait_until: polled the clock until the jump (3 reads)"
rm -f "$WU_CTR" "$WU_NOW"
# past target -> returns immediately, real clock
PAST=$(( $(date +%s) - 10 ))
MARATHON_NOW_CMD= MARATHON_SLEEP_CMD=true MARATHON_HEARTBEAT=0 marathon_wait_until "$PAST"
assert_eq "$?" "0" "wait_until: past target returns immediately"
# the 'still waiting' pulse fires during a long wait
WP_CTR=$(mktemp); echo 0 > "$WP_CTR"; WP_NOW=$(mktemp)
cat > "$WP_NOW" <<EOF
#!/usr/bin/env bash
i=\$(cat "$WP_CTR"); i=\$((i+1)); echo "\$i" > "$WP_CTR"
case "\$i" in
  1) echo 2000000 ;;
  2) echo 2000400 ;;   # 400s elapsed (> HEARTBEAT 300) -> pulse
  *) echo 2100000 ;;   # jump past target
esac
EOF
chmod +x "$WP_NOW"
WP_OUT=$(MARATHON_NOW_CMD="$WP_NOW" MARATHON_SLEEP_CMD=true MARATHON_HEARTBEAT=300 MARATHON_WAIT_POLL=60 \
  marathon_wait_until 2003600)
case "$WP_OUT" in *"still waiting for usage reset"*) WPP=yes;; *) WPP=no;; esac
assert_eq "$WPP" "yes" "wait_until: prints a 'still waiting' pulse during the wait"
rm -f "$WP_CTR" "$WP_NOW"

# --- entrypoint --status / --stop ---
SS_LOCK=$(mktemp -d); SS_NONE=$(mktemp -d)
MARATHON_LOCK_DIR="$SS_LOCK" "$BIN" --status >/dev/null 2>&1; assert_eq "$?" "0" "entrypoint: --status -> rc 0"
MARATHON_LOCK_DIR="$SS_LOCK" "$BIN" --stop >/dev/null 2>&1; assert_eq "$?" "64" "entrypoint: --stop without workdir -> rc 64"
MARATHON_LOCK_DIR="$SS_LOCK" "$BIN" --stop "$SS_NONE" >/dev/null 2>&1; assert_eq "$?" "1" "entrypoint: --stop with nothing running -> rc 1"
rm -rf "$SS_LOCK" "$SS_NONE"

# --- entrypoint --doctor / --logs / --tail ---
CLI_TMP=$(mktemp -d); printf 'line 1\nline 2\n' > "$CLI_TMP/latest.log"
MARATHON_CLAUDE_CMD="$HERE/fake-claude.sh" MARATHON_LOG_DIR="$CLI_TMP/logs" \
  MARATHON_LOCK_DIR="$CLI_TMP/locks" "$BIN" --doctor >/dev/null 2>&1
assert_eq "$?" "0" "entrypoint: --doctor -> rc 0 when required checks pass"
CLI_LOGS=$(MARATHON_LOG_DIR="$CLI_TMP" "$BIN" --logs 1)
case "$CLI_LOGS" in *latest.log* ) CLOG=yes;; *) CLOG=no;; esac
assert_eq "$CLOG" "yes" "entrypoint: --logs lists recent logs"
CLI_TAIL=$(MARATHON_LOG_DIR="$CLI_TMP" MARATHON_TAIL_FOLLOW=0 "$BIN" --tail 1 2>/dev/null)
assert_eq "$CLI_TAIL" "line 2" "entrypoint: --tail prints newest log in no-follow mode"
rm -rf "$CLI_TMP"

# --- install.sh ---
INST_TMP=$(mktemp -d)
BIN_DIR="$INST_TMP/bin" MARATHON_CLAUDE_CMD="$HERE/fake-claude.sh" \
  MARATHON_LOG_DIR="$INST_TMP/logs" MARATHON_LOCK_DIR="$INST_TMP/locks" \
  "$HERE/../install.sh" >/dev/null 2>&1
assert_eq "$?" "0" "install: symlink install completes"
[[ -L "$INST_TMP/bin/claude-marathon" ]]; assert_eq "$?" "0" "install: claude-marathon symlink created"
[[ -L "$INST_TMP/bin/marathon-launchd" ]]; assert_eq "$?" "0" "install: marathon-launchd symlink created"
[[ -L "$INST_TMP/bin/marathon-queue" ]]; assert_eq "$?" "0" "install: marathon-queue symlink created"
BIN_DIR="$INST_TMP/bin" "$HERE/../uninstall.sh" >/dev/null 2>&1
assert_eq "$?" "0" "uninstall: symlink uninstall completes"
[[ ! -e "$INST_TMP/bin/claude-marathon" ]]; assert_eq "$?" "0" "uninstall: claude-marathon symlink removed"
[[ ! -e "$INST_TMP/bin/marathon-launchd" ]]; assert_eq "$?" "0" "uninstall: marathon-launchd symlink removed"
[[ ! -e "$INST_TMP/bin/marathon-queue" ]]; assert_eq "$?" "0" "uninstall: marathon-queue symlink removed"
mkdir -p "$INST_TMP/logs" "$INST_TMP/locks"; touch "$INST_TMP/logs/x.log" "$INST_TMP/locks/x.lock"
BIN_DIR="$INST_TMP/bin" MARATHON_LOG_DIR="$INST_TMP/logs" MARATHON_LOCK_DIR="$INST_TMP/locks" \
  "$HERE/../uninstall.sh" --all >/dev/null 2>&1
assert_eq "$?" "0" "uninstall: --all completes"
[[ ! -e "$INST_TMP/logs" ]]; assert_eq "$?" "0" "uninstall: --all removes logs"
[[ ! -e "$INST_TMP/locks" ]]; assert_eq "$?" "0" "uninstall: --all removes locks"
rm -rf "$INST_TMP"

# --- release preflight ---
"$HERE/../scripts/release-check.sh" >/dev/null 2>&1
assert_eq "$?" "0" "release-check: passes with LICENSE and dated changelog"

rm -f "$NOW_FAR"

echo "-----------------------------"
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
