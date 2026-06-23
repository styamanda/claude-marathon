# Security

`claude-marathon` runs Claude Code unattended with permissions bypassed so a
task can continue without human prompts. Treat that as powerful automation.

## Safe use

- Run marathons inside a dedicated git repository or worktree.
- Review `git status` and `git diff` before keeping generated changes.
- Avoid running on directories that contain secrets, production credentials, or
  unrelated private data.
- Do not paste secrets into issue reports or logs.
- Stop a run with `claude-marathon --stop <workdir>` if it is acting on the
  wrong directory or colliding with an interactive Claude session.

## Reporting vulnerabilities

Open a GitHub issue with a minimal reproduction when the report does not expose
private data. If a report requires sensitive details, share only the high-level
symptom publicly and coordinate a private handoff with the maintainer.

Useful details:

- The exact command you ran.
- Output from `claude-marathon --doctor`.
- Output from `claude-marathon --status`.
- A redacted excerpt from the relevant marathon log.
