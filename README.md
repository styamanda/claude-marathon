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

## Known unknown

The usage-limit marker is parsed as `usage limit reached|<epoch>`. Confirm this
matches your CLI's real headless output on the first genuine limit hit; the
fallback-sleep path keeps the loop alive if the format differs.
