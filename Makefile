SHELL := /bin/bash

.PHONY: help test demo check shellcheck verify install uninstall release-check

help:
	@printf '%s\n' 'Targets:'
	@printf '  %-12s %s\n' 'test' 'Run the shell test suite'
	@printf '  %-12s %s\n' 'demo' 'Run the synthetic limit/reset demo'
	@printf '  %-12s %s\n' 'check' 'Run whitespace checks'
	@printf '  %-12s %s\n' 'shellcheck' 'Run ShellCheck if installed'
	@printf '  %-12s %s\n' 'verify' 'Run test, demo, check, and optional ShellCheck'
	@printf '  %-12s %s\n' 'install' 'Install local symlinks via install.sh'
	@printf '  %-12s %s\n' 'uninstall' 'Remove local symlinks via uninstall.sh'
	@printf '  %-12s %s\n' 'release-check' 'Run public release preflight checks'

test:
	bash test/run-tests.sh

demo:
	./claude-marathon --demo

check:
	git diff --check

shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck claude-marathon marathon-launchd marathon-queue marathon-lib.sh install.sh uninstall.sh scripts/release-check.sh test/fake-claude.sh test/run-tests.sh demo/simulated-limit.sh; \
	else \
	  echo "shellcheck not installed; skipping."; \
	fi

verify: test demo check shellcheck

install:
	./install.sh

uninstall:
	./uninstall.sh

release-check:
	./scripts/release-check.sh
