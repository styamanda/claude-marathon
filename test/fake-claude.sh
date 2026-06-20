#!/usr/bin/env bash
# Fake claude CLI for tests. Records argv, emits a canned response.
if [[ -n "${FAKE_CLAUDE_ARGV:-}" ]]; then
  printf '%s\n' "$*" > "$FAKE_CLAUDE_ARGV"
fi
if [[ -n "${FAKE_CLAUDE_OUT:-}" && -f "$FAKE_CLAUDE_OUT" ]]; then
  cat "$FAKE_CLAUDE_OUT"
fi
exit "${FAKE_CLAUDE_EXIT:-0}"
