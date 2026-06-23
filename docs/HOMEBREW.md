# Homebrew

The public tap is:

```bash
brew tap styamanda/tap
brew install claude-marathon
```

Formula:

```text
https://github.com/styamanda/homebrew-tap/blob/main/Formula/claude-marathon.rb
```

## Formula

Current `v0.1.0` formula:

```ruby
class ClaudeMarathon < Formula
  desc "Headless Claude Code auto-resume runner for long tasks and usage-limit resets"
  homepage "https://github.com/styamanda/claude-marathon"
  url "https://github.com/styamanda/claude-marathon/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "c41c208bbd5356f9bafc362b39e27e96acfdb5ae63fcbff992e80003d7f1a253"
  license "MIT"

  depends_on "jq"

  def install
    libexec.install Dir["*"]
    bin.write_exec_script libexec/"claude-marathon"
    bin.write_exec_script libexec/"marathon-launchd"
    bin.write_exec_script libexec/"marathon-queue"
  end

  test do
    assert_match "claude-marathon", shell_output("#{bin}/claude-marathon --version")
  end
end
```

For future releases, compute the release tarball checksum:

```bash
curl -L -o /tmp/claude-marathon-v0.1.0.tar.gz \
  https://github.com/styamanda/claude-marathon/archive/refs/tags/v0.1.0.tar.gz
shasum -a 256 /tmp/claude-marathon-v0.1.0.tar.gz
```

## Notes

- The formula installs the repo under `libexec` and writes wrapper scripts into
  `bin`, preserving the relative layout required by `marathon-lib.sh` and the
  demo directory.
