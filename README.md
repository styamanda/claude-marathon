# claude-marathon

Run a long Claude Code task unattended across usage-limit resets. When Claude
hits its limit, the wrapper parses the reset time, sleeps until then, and
resumes the same conversation — looping until the task is done.

## Why a script (not a slash command)

While Claude Code is rate-limited, it cannot run. The orchestrator must live
**outside** Claude, so it can sleep through the reset window and relaunch the
CLI. A slash command runs inside the very session that is frozen.

## Usage

    ./claude-marathon "Refactor module X and make all tests pass" /path/to/repo

Completion is signalled by Claude creating a `.marathon-done` file as its final
action. The loop checks for it after every run.

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
| `MARATHON_FALLBACK_SLEEP` | 1800 | Sleep when reset time can't be parsed |
| `MARATHON_BUFFER` | 60 | Extra seconds added after reset |
| `MARATHON_LOG_DIR` | `~/.claude/marathon-logs` | Per-iteration logs |
| `MARATHON_SENTINEL` | `.marathon-done` | Completion sentinel filename |
| `MARATHON_NOTIFY` | auto | `auto` / `echo` / `off` |

## Tests

    bash test/run-tests.sh

## Usage-limit detection

Verified against Claude Code CLI **v2.1.183**. Limit detection accepts three
signals, most precise first:

1. **`resetsAt`** — a JSON field carrying the reset time as Unix epoch seconds
   (the CLI derives it from the `anthropic-ratelimit-unified-reset` response
   header). Used to sleep exactly until reset.
2. Legacy `usage limit reached|<epoch>` pipe-delimited text (older builds).
3. The bare phrase `usage limit reached` with no machine-readable time — the
   loop falls back to `MARATHON_FALLBACK_SLEEP` (default 30 min) and retries.

The exact shape of the headless `--print --output-format json` payload during a
real limit could not be triggered on demand; signal (3) guarantees the loop
keeps working even if the payload omits `resetsAt`. On your first genuine limit
hit, check the log: a "sleeping Ns until reset" line with N in the thousands
means `resetsAt` was found; repeated 1800s sleeps mean it fell back to (3).
