#!/usr/bin/env bash
set -uo pipefail

fail=0

check() {
  local name="$1"; shift
  if "$@"; then
    printf 'OK    %s\n' "$name"
  else
    printf 'FAIL  %s\n' "$name"
    fail=1
  fi
}

has_file() {
  [[ -f "$1" ]]
}

has_text() {
  local file="$1" pattern="$2"
  [[ -f "$file" ]] && grep -q "$pattern" "$file"
}

check "LICENSE exists" has_file LICENSE
check "LICENSE is MIT" has_text LICENSE '^MIT License$'
check "CHANGELOG has dated 0.1.0 entry" has_text CHANGELOG.md '^## 0\.1\.0 - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$'
check "README mentions install.sh" has_text README.md './install.sh'
check "README mentions claude-marathon --demo" has_text README.md 'claude-marathon --demo'
check "README mentions SECURITY.md" has_text README.md 'SECURITY.md'
check "Release checklist mentions repo metadata" has_text RELEASE.md 'docs/REPO_METADATA.md'
check "Homebrew formula uses MIT license" has_text docs/HOMEBREW.md 'license "MIT"'

if (( fail )); then
  echo
  echo "Release preflight failed. Fix the FAIL items before tagging."
  exit 1
fi

echo
echo "Release preflight passed."
