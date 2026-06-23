# Contributing

Thanks for helping make `claude-marathon` sturdier.

## Development loop

```bash
make verify
```

That wraps:

```bash
bash test/run-tests.sh
./claude-marathon --demo
git diff --check
```

The test suite is macOS-oriented because it validates launchd plist rendering,
`plutil`, and BSD `date` behavior. The foreground runner is plain shell, but CI
currently treats macOS as the reference platform.

If you have `shellcheck` installed, `make verify` also runs it. To run only
ShellCheck:

```bash
make shellcheck
```

Before tagging a release, run:

```bash
make release-check
```

## Bug reports

Please include:

- macOS version, shell, and Claude Code CLI version.
- The exact command you ran.
- Output from `claude-marathon --doctor`.
- Output from `claude-marathon --status`.
- The relevant log from `claude-marathon --logs` or `claude-marathon --tail`.

Do not paste secrets, API keys, private code, or full transcripts containing
sensitive repository details.

## Design preference

Keep the runner small and boring. Prefer shell primitives, clear logs,
deterministic tests, and recovery commands users can copy directly.
