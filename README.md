# claude-marathon

Run a long Claude Code task unattended across usage-limit resets. When Claude
hits its limit, the wrapper parses the reset time, sleeps until then, and
resumes the same conversation — looping until the task is done.

## Install

macOS, with the `claude` CLI on your PATH, plus `jq`. (The foreground
`claude-marathon` and the queue work on any Unix; only the detached
`marathon-launchd` and the `--watch` log window are macOS-specific.)

    # 1. Clone
    git clone https://github.com/styamanda/claude-marathon.git ~/Projects/claude-marathon
    cd ~/Projects/claude-marathon

    # 2. Make the scripts runnable
    chmod +x claude-marathon marathon-launchd marathon-queue

    # 3. Put them on your PATH (symlinks, so `git pull` updates them in place)
    mkdir -p ~/.local/bin
    ln -sf "$PWD/claude-marathon"  ~/.local/bin/
    ln -sf "$PWD/marathon-launchd" ~/.local/bin/
    ln -sf "$PWD/marathon-queue"   ~/.local/bin/

    # 4. Verify (ensure ~/.local/bin is on your PATH)
    claude-marathon --version          # -> claude-marathon 0.1.0

Update later with `git -C ~/Projects/claude-marathon pull`; the symlinks pick up
the new version automatically.

> Always use **straight** quotes (`"`) around the task. Curly quotes (`“ ”`)
> pasted from a notes app or editor are not treated as quoting by the shell; the
> tool detects them and refuses with a clear error rather than mangling the task.

## Why a script (not a slash command)

While Claude Code is rate-limited, it cannot run. The orchestrator must live
**outside** Claude, so it can sleep through the reset window and relaunch the
CLI. A slash command runs inside the very session that is frozen.

## Usage

    ./claude-marathon "Refactor module X and make all tests pass" /path/to/repo

Completion is signalled by Claude creating a `.marathon-done` file as its final
action. The loop checks for it after every run.

### Resuming a specific existing session

By default the first iteration starts a fresh conversation. To instead continue
a specific conversation you started interactively, pass its session id:

    ./claude-marathon --resume <session-id> "Continue where we left off" /path/to/repo
    ./marathon-launchd --resume <session-id> "Continue where we left off" /path/to/repo

Find session ids with `claude --resume` (interactive picker) or under
`~/.claude/projects/`. The id is used on the **first** iteration only; later
iterations use `--continue`, which follows the most recent conversation in the
working directory. Do not run this while an interactive session in the same
directory is still open — both would resume the same conversation and collide.

For an overnight run that survives terminal/laptop sleep:

    caffeinate -i nohup ./claude-marathon "..." /path/to/repo &

## Run as a managed LaunchAgent (recommended for overnight)

`marathon-launchd` installs a macOS LaunchAgent so the run is fully detached
from any terminal (survives logout), `caffeinate`-wrapped so the Mac won't
sleep, and **self-removing** when the task finishes — so it will not re-run on
your next login or reboot.

    ./marathon-launchd "Refactor module X and make all tests pass" /path/to/repo

Inspect the plist before loading:

    ./marathon-launchd --dry-run "..." /path/to/repo

A desktop notification fires the moment a job loads so you know it started. To
watch it work live, add `--watch` — it opens a Terminal window tailing the log:

    ./marathon-launchd --watch "..." /path/to/repo

The task text is passed through the plist's `EnvironmentVariables`, never
shell-interpolated, so quotes and special characters in the task are safe.
Logs and the plist are labelled `com.claude-marathon.<timestamp>`. Stop a run
early with the `launchctl bootout ...` command printed at install time.

## Safety

- Runs with `--permission-mode bypassPermissions` (fully unattended). **Run it
  inside a dedicated git repo or worktree** so changes are contained/reversible.
- Caps: max 20 iterations, 2h per-run timeout. Override via env vars.
- Every iteration is logged to `~/.claude/marathon-logs/`.

## Env overrides

| Var | Default | Meaning |
|-----|---------|---------|
| `MARATHON_MAX_ITERS` | 20 | Hard cap on loop iterations |
| `MARATHON_TIMEOUT` | 7200 | Per-run timeout (seconds) |
| `MARATHON_FALLBACK_SLEEP` | 300 | Sleep when reset time can't be parsed (short-poll) |
| `MARATHON_BUFFER` | 60 | Extra seconds added after reset |
| `MARATHON_LOG_DIR` | `~/.claude/marathon-logs` | Per-iteration logs |
| `MARATHON_SENTINEL` | `.marathon-done` | Completion sentinel filename |
| `MARATHON_NOTIFY` | auto | `auto` / `echo` / `off` |

## Tests

    bash test/run-tests.sh

## Usage-limit detection

Verified against a **real** Claude Code CLI v2.1.183 limit. The headless result
during a session limit looks like:

    {"is_error":true,"result":"You've hit your session limit · resets 8pm (Europe/London)"}

There is no machine-readable reset epoch in that payload, so detection works by
matching the message text and the loop then **fallback-sleeps and retries**
until the limit clears. Detection accepts, most precise first:

1. **`resetsAt`** — a JSON epoch field, if present → sleep exactly until reset.
2. Legacy `usage limit reached|<epoch>` pipe-delimited text (older builds).
3. The phrasing `hit your session/usage limit`, `... limit reached/exceeded`,
   etc. with no epoch → fallback-sleep (`MARATHON_FALLBACK_SLEEP`, default
   5 min) and short-poll until the limit clears.

Limit waits do **not** consume the iteration budget (`MARATHON_MAX_ITERS`); a
separate `MARATHON_MAX_LIMIT_WAITS` (default 96) bounds how long it will keep
retrying a persistent limit before giving up (exit code 3). On a real limit the
log shows `Rate/usage limit hit; sleeping Ns, then retrying (wait k/96)`.

## Multiple tasks (queue)

`marathon-queue <file> [workdir]` runs several tasks back-to-back, each as its
own fresh isolated session. Tasks in the file are separated by a line containing
only `---`. Continues past failures by default; `--stop-on-fail` halts on the
first. Run it detached overnight via `marathon-launchd --queue <file> [workdir]`.
