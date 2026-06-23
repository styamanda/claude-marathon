# Release Checklist

Use this when cutting a public GitHub release.

## Before tagging

- Run `make verify`.
- Run `make release-check` and resolve any failures.
- Confirm `claude-marathon --doctor` gives useful output on a normal install.
- Confirm the README quick start matches the released command names.
- Choose and add a real project license before the first public release.
- Update `CHANGELOG.md` from `unreleased` to the release date.
- Apply the description and topics from `docs/REPO_METADATA.md`.
- If publishing through Homebrew, prepare the tap formula from
  `docs/HOMEBREW.md` after the tag exists.

## Tag and publish

```bash
git tag -a v0.1.0 -m "claude-marathon v0.1.0"
git push origin main --tags
```

Create a GitHub release from the tag with:

- A one-paragraph summary.
- The changelog highlights.
- Known limitations:
  detached launch mode is macOS-specific, and closed-lid sleep pauses progress.

## Suggested repo topics

`claude-code`, `auto-resume`, `rate-limit`, `launchd`, `macos`,
`coding-agent`, `automation`, `shell-script`
