# Changelog

## Unreleased

### Added

- `marathon-launchd --list` to show loaded LaunchAgents, workdirs/logs when
  available, and exact `launchctl bootout` commands.

## 0.1.0 - 2026-06-23

First community-ready release candidate.

### Added

- Headless Claude Code marathon loop that resumes with `--continue` after
  usage-limit waits.
- `marathon-launchd` for detached macOS LaunchAgent runs.
- `marathon-queue` for back-to-back task batches.
- Completion sentinel contract via `.marathon-done`.
- Per-directory locking and collision checks for interactive Claude sessions.
- Clean stop/status commands:
  `claude-marathon --status` and `claude-marathon --stop <workdir>`.
- Live stream-json log narration with a `MARATHON_NO_STREAM=1` fallback.
- Log helpers: `claude-marathon --logs` and `claude-marathon --tail`.
- Setup helper: `claude-marathon --doctor`.
- Help output for all entrypoints and `claude-marathon --demo`.
- Local symlink installer via `./install.sh`.
- Local symlink uninstaller via `./uninstall.sh`.
- Release preflight checks via `make release-check`.
- Simulated limit/reset demo via `./demo/simulated-limit.sh`.
- MIT license.
- Homebrew tap formula at `styamanda/tap/claude-marathon`.
- GitHub CI workflow, issue templates, contribution notes, release checklist,
  security notes, Homebrew formula template, and recommended repo metadata.

### Notes

- The detached launch helper is macOS-specific.
- Closed-lid laptop sleep still pauses all progress; leave the Mac plugged in
  with the lid open for true overnight runs.
