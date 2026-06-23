---
name: Bug report
about: Report a broken run, resume problem, launchd issue, or bad log output
title: "Bug: "
labels: bug
assignees: ""
---

## What happened?

Describe the failure and what you expected instead.

## Command

```bash
# paste the exact command
```

## Environment

```bash
sw_vers
claude --version
claude-marathon --doctor
```

## Status and logs

```bash
claude-marathon --status
claude-marathon --logs
```

Paste the relevant log excerpt. Please remove secrets, private code, and
sensitive transcript details.

## Notes

Anything else that might matter, such as battery/lid state, worktree layout, or
whether another Claude session was open in the same directory.
