# Homebrew

The public tap is:

```bash
brew tap styamanda/tap
brew trust styamanda/tap
brew install claude-marathon
```

Formula:

```text
https://github.com/styamanda/homebrew-tap/blob/main/Formula/claude-marathon.rb
```

## Formula Updates

The exact formula lives in the tap repo. For a new release, create and push the
tag first, then compute the release tarball checksum:

```bash
VERSION=$(./claude-marathon --version | awk '{print $2}')
curl -L -o "/tmp/claude-marathon-v${VERSION}.tar.gz" \
  "https://github.com/styamanda/claude-marathon/archive/refs/tags/v${VERSION}.tar.gz"
shasum -a 256 "/tmp/claude-marathon-v${VERSION}.tar.gz"
```

Update `Formula/claude-marathon.rb` in `styamanda/homebrew-tap`, then run:

```bash
brew audit --strict --formula claude-marathon
brew reinstall claude-marathon
brew test claude-marathon
```

## Notes

- The formula installs the repo under `libexec` and writes wrapper scripts into
  `bin`, preserving the relative layout required by `marathon-lib.sh` and the
  demo directory.
