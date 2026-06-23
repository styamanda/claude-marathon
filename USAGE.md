# claude-marathon — Usage Runbook

Step-by-step procedures for running a task. For design/internals see `README.md`.

## 0. Prerequisites (one-time, already set up)

- `claude-marathon` and `marathon-launchd` are on your PATH (symlinks in
  `~/.local/bin`).
- Confirm anytime:

      claude-marathon --doctor       # environment and PATH check
      claude-marathon --demo         # synthetic limit/reset demo
      claude-marathon --version      # -> claude-marathon 0.1.0

## 1. Prepare the working directory

Use a **dedicated git repo** — the tool runs Claude unattended with permissions
bypassed, so changes should be contained and reversible.

    cd /path/to/your/repo
    git status                       # confirm it's a repo
    git switch -c marathon-run       # optional throwaway isolation branch

If it isn't a repo yet: `git init`.

## 2. Run a task

### 2A. New task, overnight / unattended (main use case)

    marathon-launchd "Refactor the auth module and make all tests pass" /path/to/your/repo

Installs a LaunchAgent that runs detached (survives logout), `caffeinate`-wrapped,
and self-removes when done. Preview without launching:

    marathon-launchd --dry-run "your task" /path/to/your/repo

> **Overnight on a laptop:** plug in and **leave the lid open.** `caffeinate`
> stops *idle* sleep but not *lid-close* sleep — close the lid and macOS sleeps,
> pausing the run until you reopen it (it resumes cleanly on wake, but does no
> work while asleep). `marathon-launchd` warns you when you launch on battery.

**Know it's running:** a desktop notification fires the moment it loads. To
*watch it work live*, add `--watch` — it opens a Terminal window tailing the log:

    marathon-launchd --watch "your task" /path/to/your/repo

> Always use **straight** quotes (`"`). Curly quotes (`“ ”`) from a notes app or
> editor are not treated as quotes by the shell — the tool now detects them and
> refuses with a clear error instead of mangling your task.

### 2B. New task, foreground (you're watching)

    claude-marathon "your task" /path/to/your/repo

Runs in your terminal. Closing the terminal kills it — use 2A for long jobs.

### 2D. Multiple tasks in one night (queue)

Put several tasks in a file, separated by a line containing only `---`. Each
task runs as its own fresh isolated session, back-to-back.

    cat > night.txt <<'TASKS'
    Add dark mode to the settings page and test it.
    ---
    Fix the failing checkout tests.
    ---
    Update the README with both changes.
    TASKS

    marathon-queue night.txt /path/to/your/repo                 # foreground
    marathon-launchd --queue night.txt /path/to/your/repo       # detached overnight

By default the queue continues past a failed task; add `--stop-on-fail` to halt
on the first failure. A summary (done/failed per task) prints at the end.

### 2C. Continue a specific existing session

    claude --resume                  # interactive picker; copy the session id
    marathon-launchd --resume <session-id> "Continue where we left off" /path/to/your/repo

Only the first iteration resumes that id; later iterations use `--continue`.
Do NOT have an interactive session open in the same directory at the same time.

## 3. Write the task well

- State the goal and the done-condition plainly:
  "…until `npm test` passes with zero failures."
- Point to durable state, not memory: "the plan is in NOTES.md", "work on the
  `feature-x` branch."
- The tool automatically instructs Claude to create `.marathon-done` as its
  final action — you don't add that yourself.

## 4. Monitor a running job

    claude-marathon --status         # running/stale jobs and launchd labels
    claude-marathon --logs           # recent logs, newest first
    claude-marathon --tail           # tail the newest log

The job is headless: it streams to the log, not to the VS Code extension or the
Claude Code app (those show interactive sessions only). Watch it live in a
terminal — `marathon-launchd --watch` auto-opens a window, and
`claude-marathon --tail` follows the newest log.

In the log, look for:

- `→ iteration N/M: claude is working` -> an iteration started; its work then
  streams in live below
- `claude: …` -> a message from Claude as it works
- `🔧 <tool>: …` -> a tool call (`🔧 Bash: …`, `🔧 Write: …`) as Claude makes it
- `● result: <subtype>` -> the iteration's turn ended (success / error)
- `… still working (~Nm elapsed)` -> heartbeat filling a silent stretch (thinking / long tool)
- `waiting ~<N>s (until HH:MM:SS)` -> hit a usage limit, waiting until that
  wake time (working as intended). The wait is timed against the real clock, so
  it survives the Mac sleeping — it resumes the moment the machine wakes.
- `… still waiting for usage reset (~Nm left, until HH:MM)` -> pulse while it
  waits out a limit, so a long wait never looks frozen
- `DONE after N iteration(s)`  -> finished
- `ERROR stop:` / `CAP reached:` / `GAVE UP:` -> stopped; read why

## 5. When it finishes

- Desktop notification fires on completion/error.
- A `.marathon-done` file appears in the working directory.
- The LaunchAgent removes its own plist (won't re-run on reboot).

Review the work:

    cd /path/to/your/repo
    git status && git diff
    git log --oneline

## One marathon per directory

Two marathons in the **same** directory collide (they share the conversation and
the `.marathon-done` file). The tool now prevents this automatically: a running
marathon holds a lock on its workdir, and a second one targeting the same
directory refuses to start:

    error: a marathon is already running for /path/to/repo.

Different directories can run in parallel safely. To run something else in the
same repo, stop the current job first (see below). Locks live in
`~/.claude/marathon-locks/` and are reclaimed automatically if a job crashed
(stale lock from a dead process). To clear one by hand: `rm -rf ~/.claude/marathon-locks/`.

## 6. Stop a job early

    claude-marathon --status                   # see what's running (state, pid, workdir)
    claude-marathon --stop /path/to/repo       # stop that repo's marathon cleanly + clear its lock

`--stop` signals the whole process tree (so the underlying `claude` can't keep
running) and escalates to SIGKILL only if the job ignores the polite stop. It
also works on a detached `marathon-launchd` job — the LaunchAgent self-removes
when its worker exits. The lower-level equivalent still works too:

    launchctl bootout gui/$(id -u)/<label>     # label is printed at launch / is the log filename

For a foreground run: `Ctrl-C`.

## 7. Tuning (optional env vars, prepend to the command)

    MARATHON_MAX_ITERS=40 MARATHON_TIMEOUT=10800 \
      marathon-launchd "big task" /path/to/repo

| Var | Default | Meaning |
|-----|---------|---------|
| `MARATHON_MAX_ITERS` | 20 | Max loop iterations before giving up |
| `MARATHON_TIMEOUT` | 7200 | Per-run timeout (seconds) |
| `MARATHON_FALLBACK_SLEEP` | 300 | Sleep when reset time isn't parseable (short-poll) |
| `MARATHON_BUFFER` | 60 | Extra seconds added after a reset |
| `MARATHON_LOG_DIR` | `~/.claude/marathon-logs` | Where logs go |
| `MARATHON_SENTINEL` | `.marathon-done` | Completion sentinel filename |
| `MARATHON_NOTIFY` | auto | `auto` / `echo` / `off` |
| `MARATHON_HEARTBEAT` | 300 | Seconds between "still working"/"still waiting" pulses (0 = off) |
| `MARATHON_WAIT_POLL` | 60 | Limit-wait poll interval (s) — how soon it resumes after the Mac wakes |
| `MARATHON_ALLOW_SHARED_DIR` | unset | Set `1` to skip the "another Claude session is active here" guard |

## Quick reference (the 90% case)

    cd /path/to/repo
    claude-marathon --doctor
    claude-marathon --demo
    marathon-launchd "do X until tests pass" .
    claude-marathon --tail
    # ...later...
    git -C /path/to/repo diff
