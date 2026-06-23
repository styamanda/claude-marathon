# Repository Metadata

Recommended GitHub settings for discoverability.

## Repository description

```text
Headless Claude Code auto-resume runner for long tasks, usage-limit resets, launchd, logs, and queues.
```

## Topics

```text
claude-code
auto-resume
rate-limit
launchd
macos
coding-agent
automation
shell-script
```

## Social preview / tagline

```text
Claude hit a limit. Let the marathon wait, resume, and finish the job.
```

## Launch post draft

```markdown
I built `claude-marathon`, a headless auto-resume runner for Claude Code.

Most auto-continue tools watch a tmux pane and type `continue`. That is great
for interactive sessions. This is for detached long-running jobs: it runs
Claude Code headlessly, detects usage-limit resets, waits against the wall
clock, resumes with `--continue`, streams progress to logs, and stops cleanly
when `.marathon-done` appears.

Best fit: overnight tasks on macOS, launchd, queues, logs, and clean stop/status
commands.

Repo: https://github.com/styamanda/claude-marathon
```
