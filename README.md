# claude-marathon

[![CI](https://github.com/styamanda/claude-marathon/actions/workflows/ci.yml/badge.svg)](https://github.com/styamanda/claude-marathon/actions/workflows/ci.yml)

Run long Claude Code tasks unattended across usage-limit resets.

Claude hits a limit at 2am, the terminal is gone, and the task is only half
done. `claude-marathon` runs Claude Code from outside the session, waits through
the reset window, resumes the same conversation, streams progress to logs, and
stops only when Claude creates the completion sentinel.

## What makes it different

Most Claude auto-resume tools watch an interactive tmux pane and type
`continue` when the reset time passes. That is great when you want to keep using
Claude's TUI. `claude-marathon` is for the other case: a headless, detached job
that should keep going even after you close the terminal.

| Tool | Best fit | How it resumes |
|------|----------|----------------|
| `claude-marathon` | Detached long-running jobs, overnight work, queues, clean stop/status | Headless `claude -p`, result parsing, `--continue`, launchd |
| [`claude-auto-retry`](https://github.com/cheapestinference/claude-auto-retry) | Keep normal interactive Claude sessions alive | tmux capture-pane + send `continue` |
| [`autoclaude`](https://github.com/henryaj/autoclaude) | TUI dashboard for multiple tmux panes | tmux pane polling + send `continue` |
| [`claude-auto-resume`](https://github.com/terryso/claude-auto-resume) | Small wait-and-rerun wrapper | CLI output parsing + rerun Claude |

Use `claude-marathon` when you want locks, detached macOS launchd execution,
streamed logs, completion sentinels, queues, and a stop command that kills the
whole process tree. Use a tmux helper when the live interactive Claude UI is the
main thing you want.

## Install

Requirements: macOS or Unix shell, Claude Code CLI on your PATH, and `jq`.
The foreground runner and queue are Unix-friendly; `marathon-launchd`, desktop
notifications, and `--watch` are macOS-specific.

Homebrew:

    brew tap styamanda/tap
    brew trust styamanda/tap
    brew install claude-marathon

Source checkout:

    # 1. Clone and install symlinks
    git clone https://github.com/styamanda/claude-marathon.git ~/Projects/claude-marathon
    cd ~/Projects/claude-marathon
    ./install.sh

    # 2. Verify setup
    claude-marathon --doctor

The installer creates symlinks in `~/.local/bin` by default, so `git pull`
updates the commands in place. Override with `BIN_DIR=/custom/bin ./install.sh`.

Uninstall symlinks later with:

    ./uninstall.sh

Update later with:

    git -C ~/Projects/claude-marathon pull
    claude-marathon --doctor

> Always use **straight** quotes (`"`) around the task. Curly quotes (`“ ”`)
> pasted from a notes app or editor are not treated as quoting by the shell; the
> tool detects them and refuses with a clear error rather than mangling the task.

## Quick start

    cd /path/to/repo
    marathon-launchd "Refactor module X and make all tests pass" .

Watch it:

    claude-marathon --tail

Stop it:

    claude-marathon --stop /path/to/repo

Check recent runs:

    claude-marathon --status
    claude-marathon --logs
    marathon-launchd --list

Try a local simulated limit/reset run without using real Claude quota:

    claude-marathon --demo

## Best for / not for

Best for:

- Long tasks that may hit Claude usage limits before completion.
- Overnight detached runs on a plugged-in Mac with the lid open.
- Repos or worktrees where unattended edits are contained and reversible.
- Batch work via `marathon-queue`.

Not for:

- Live interactive Claude Code sessions where you want the full TUI visible.
- Closed-lid laptop work. macOS sleeps; no script can make progress while the
  machine is actually asleep.
- Production directories or sensitive machines where bypassed permissions are
  unacceptable.

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
early with `claude-marathon --stop /path/to/repo`, or find the launchd label
and lower-level stop command later with:

    ./marathon-launchd --list

## Safety

- Runs with `--permission-mode bypassPermissions` (fully unattended). **Run it
  inside a dedicated git repo or worktree** so changes are contained/reversible.
- Caps: max 20 iterations, 2h per-run timeout. Override via env vars.
- Every iteration is logged to `~/.claude/marathon-logs/`.

See `SECURITY.md` for the threat model and safe-use checklist.

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
| `MARATHON_HEARTBEAT` | 300 | Seconds between "still working"/"still waiting" log pulses (0 = off) |
| `MARATHON_WAIT_POLL` | 60 | Limit-wait poll interval (s) — how soon it resumes after the Mac wakes |
| `MARATHON_ALLOW_SHARED_DIR` | unset | Set `1` to skip the "another Claude session is active here" guard |
| `MARATHON_NO_STREAM` | unset | Set `1` to disable live streaming (`stream-json`) and capture one result blob per iteration instead |

## Reading the live log

Each iteration streams Claude's work to the log **as it happens** (via
`--output-format stream-json`): a start line, then each assistant message
(`claude: …`) and tool call (`🔧 Bash: …`, `🔧 Write: …`) as Claude makes it,
then `● result: <subtype>` when the turn ends. A heartbeat
(`… still working (~Nm elapsed)`) every `MARATHON_HEARTBEAT` seconds fills any
silent stretch (the model thinking, or a long tool emitting no events). When a
usage limit is hit the log shows the wait **and the absolute wake time**, e.g.
`waiting ~13380s (until 10:41:04 BST), then retrying`, and pulses
`… still waiting for usage reset (~Nm left, until HH:MM)` while it waits.

The limit wait is timed against the **real wall clock**, not a fixed-duration
`sleep`, so it survives the Mac sleeping: if the machine sleeps mid-wait, the
run resumes the moment it wakes instead of freezing with the countdown stuck.

A marathon is headless, so it cannot be watched from the VS Code extension or
the Claude Code app (those are for interactive sessions) — the terminal is the
place: `--watch` (auto-opens a window) or `tail -F` the log. Set
`MARATHON_NO_STREAM=1` to revert to the older single-blob output (one result
line at the end, no live narration).

## Laptop sleep & overnight runs

`caffeinate` keeps the Mac awake only while the **lid is open**. Closing the lid
(especially on battery) sleeps the whole Mac, and a sleeping Mac makes no
progress — no software the job runs can override a closed-lid sleep. Because the
limit wait is sleep-resilient, a job picks up where it left off when you reopen
the laptop, but it will **not** advance overnight with the lid shut.

For a real overnight run: **plug in and leave the lid open.** `marathon-launchd`
prints a warning when you launch on battery.

## Inspecting and stopping runs

    claude-marathon --status              # list every marathon: state, pid, workdir
    marathon-launchd --list               # list loaded LaunchAgents and bootout commands
    claude-marathon --stop /path/to/repo  # stop the marathon for that repo, cleanly

`--stop` signals the whole process tree (so the underlying `claude` can't keep
running) and clears the lock, escalating to `SIGKILL` only if a job ignores the
polite stop. A marathon now also exits cleanly on `launchctl bootout` / `kill`
(it releases its lock and actually terminates, rather than lingering as an
orphan that holds a stale lock). Use `marathon-launchd --list` when you need the
exact `launchctl bootout gui/<uid>/<label>` command for a detached job.

## Tests

    make verify

Or run the pieces directly:

    bash test/run-tests.sh
    claude-marathon --demo
    git diff --check

Before a public release, run:

    make release-check

For contribution and release workflow details, see `CONTRIBUTING.md`,
`CHANGELOG.md`, `RELEASE.md`, `SECURITY.md`, `docs/DEMO.md`,
`docs/HOMEBREW.md`, and `docs/REPO_METADATA.md`.

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
log shows `Rate/usage limit hit; waiting ~Ns (until HH:MM:SS TZ), then retrying
(wait k/96)`.

## Multiple tasks (queue)

`marathon-queue <file> [workdir]` runs several tasks back-to-back, each as its
own fresh isolated session. Tasks in the file are separated by a line containing
only `---`. Continues past failures by default; `--stop-on-fail` halts on the
first. Run it detached overnight via `marathon-launchd --queue <file> [workdir]`.

## License

MIT. See `LICENSE`.
