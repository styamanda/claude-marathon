#!/usr/bin/env bash
set -uo pipefail

fail=0
version=$(./claude-marathon --version 2>/dev/null | awk '{print $2}')

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
check "claude-marathon reports a version" test -n "$version"
check "CHANGELOG has dated $version entry" has_text CHANGELOG.md "^## ${version//./\\.} - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$"
check "README mentions install.sh" has_text README.md './install.sh'
check "README mentions claude-marathon --demo" has_text README.md 'claude-marathon --demo'
check "README mentions SECURITY.md" has_text README.md 'SECURITY.md'
check "Release checklist mentions repo metadata" has_text RELEASE.md 'docs/REPO_METADATA.md'
check "Homebrew docs link the tap formula" has_text docs/HOMEBREW.md 'styamanda/homebrew-tap'

if (( fail )); then
  echo
  echo "Release preflight failed. Fix the FAIL items before tagging."
  exit 1
fi

echo
echo "Release preflight passed."
