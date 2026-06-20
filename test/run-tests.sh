#!/usr/bin/env bash
# Dependency-free bash test runner for claude-marathon.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../marathon-lib.sh
source "$HERE/../marathon-lib.sh"

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

# --- harness self-test ---
assert_eq "$(marathon_version)" "claude-marathon 0.1.0" "marathon_version returns version string"

# --- classify_result ---
assert_eq "$(classify_result "$(cat "$HERE/fixtures/limit.json")" 0)" \
  "LIMIT 1750464000" "classify: usage limit -> LIMIT epoch"
assert_eq "$(classify_result "$(cat "$HERE/fixtures/success.json")" 0)" \
  "OK" "classify: clean success -> OK"
assert_eq "$(classify_result "$(cat "$HERE/fixtures/error.json")" 0)" \
  "ERROR Something broke during execution." "classify: is_error true -> ERROR msg"
assert_eq "$(classify_result "$(cat "$HERE/fixtures/malformed.txt")" 0)" \
  "OK" "classify: malformed non-error output -> OK"
assert_eq "$(classify_result "$(cat "$HERE/fixtures/malformed.txt")" 7)" \
  "ERROR exit_code=7" "classify: malformed + nonzero exit -> ERROR"

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

# --- run_iteration ---
chmod +x "$HERE/fake-claude.sh"
ITER_TMP=$(mktemp -d)
export FAKE_CLAUDE_OUT="$HERE/fixtures/success.json"
export FAKE_CLAUDE_ARGV="$ITER_TMP/argv.txt"
MARATHON_CLAUDE_CMD="$HERE/fake-claude.sh" \
  run_iteration 0 "$ITER_TMP" "Build the thing" "$ITER_TMP/out0.log"
assert_eq "$?" "0" "iteration: returns underlying exit code"
assert_eq "$(grep -c 'Did some work' "$ITER_TMP/out0.log")" "1" "iteration: writes claude output to logfile"
assert_eq "$(grep -c -- '--continue' "$ITER_TMP/argv.txt")" "0" "iteration 0: seed run has no --continue"

MARATHON_CLAUDE_CMD="$HERE/fake-claude.sh" \
  run_iteration 1 "$ITER_TMP" "Build the thing" "$ITER_TMP/out1.log"
assert_eq "$(grep -c -- '--continue' "$ITER_TMP/argv.txt")" "1" "iteration 1: resume run uses --continue"
unset FAKE_CLAUDE_OUT FAKE_CLAUDE_ARGV
rm -rf "$ITER_TMP"

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

rm -rf "$LOOP_TMP" "$CAP_TMP" "$ERR_TMP"

# --- entrypoint ---
BIN="$HERE/../claude-marathon"
chmod +x "$BIN" 2>/dev/null || true
"$BIN" >/dev/null 2>&1; assert_eq "$?" "64" "entrypoint: no args -> usage exit 64"
assert_eq "$("$BIN" --version)" "claude-marathon 0.1.0" "entrypoint: --version prints version"

echo "-----------------------------"
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
