# claude-marathon — Usage Runbook

Step-by-step procedures for running a task. For design/internals see `README.md`.

## 0. Prerequisites (one-time, already set up)

- `claude-marathon` and `marathon-launchd` are on your PATH (symlinks in
  `~/.local/bin`).
- Confirm anytime:

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

Installs a LaunchAgent that runs detached (survives logout), `caffeinate`-wrapped
(Mac won't sleep), and self-removes when done. Preview without launching:

    marathon-launchd --dry-run "your task" /path/to/your/repo

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

    ls -lt ~/.claude/marathon-logs/
    tail -f ~/.claude/marathon-logs/com.claude-marathon.*.log
    launchctl list | grep claude-marathon

In the log, look for:

- `sleeping <N>s until reset`  -> hit a usage limit, waiting (working as intended)
- `DONE after N iteration(s)`  -> finished
- `ERROR stop:` / `CAP reached:` -> stopped; read why

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

## Quick reference (the 90% case)

    cd /path/to/repo
    marathon-launchd "do X until tests pass" .
    # ...later...
    git -C /path/to/repo diff
