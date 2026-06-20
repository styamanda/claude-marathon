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

### 2B. New task, foreground (you're watching)

    claude-marathon "your task" /path/to/your/repo

Runs in your terminal. Closing the terminal kills it — use 2A for long jobs.

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
| `MARATHON_FALLBACK_SLEEP` | 1800 | Sleep when reset time isn't parseable |
| `MARATHON_BUFFER` | 60 | Extra seconds added after a reset |
| `MARATHON_LOG_DIR` | `~/.claude/marathon-logs` | Where logs go |
| `MARATHON_SENTINEL` | `.marathon-done` | Completion sentinel filename |
| `MARATHON_NOTIFY` | auto | `auto` / `echo` / `off` |

## Quick reference (the 90% case)

    cd /path/to/repo
    marathon-launchd "do X until tests pass" .
    # ...later...
    git -C /path/to/repo diff
