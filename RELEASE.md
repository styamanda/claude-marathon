# Release Checklist

Use this when cutting a public GitHub release.

## Before tagging

- Run `make verify`.
- Run `make release-check` and resolve any failures.
- Confirm `claude-marathon --doctor` gives useful output on a normal install.
- Confirm the README quick start matches the released command names.
- Confirm `LICENSE` and the Homebrew formula use the intended license.
- Confirm `CHANGELOG.md` has the release date.
- Apply the description and topics from `docs/REPO_METADATA.md`.
- If publishing through Homebrew, prepare the tap formula from
  `docs/HOMEBREW.md` after the tag exists.

## Tag and publish

```bash
VERSION=$(./claude-marathon --version | awk '{print $2}')
git tag -a "v${VERSION}" -m "claude-marathon v${VERSION}"
git push origin main "v${VERSION}"
```

Create a GitHub release from the tag with:

- A one-paragraph summary.
- The changelog highlights.
- Known limitations:
  detached launch mode is macOS-specific, and closed-lid sleep pauses progress.

## Suggested repo topics

`claude-code`, `auto-resume`, `rate-limit`, `launchd`, `macos`,
`coding-agent`, `automation`, `shell-script`
