# Demo

Run a short deterministic demo without calling the real Claude CLI:

```bash
claude-marathon --demo
```

From a source checkout, this is equivalent to:

```bash
./demo/simulated-limit.sh
```

The demo uses the real `claude-marathon` loop with a fake Claude command:

1. First iteration emits a synthetic usage-limit result with a reset one second
   in the future.
2. `claude-marathon` detects the limit, waits against the wall clock, and
   retries without consuming the productive iteration budget.
3. Second iteration streams an assistant message and tool event, creates
   `.marathon-done`, and exits successfully.

This is useful for:

- Recording a README GIF or asciinema.
- Checking the log format without waiting for a real account limit.
- Showing contributors how the sentinel and resume loop fit together.

The script uses a temp workdir and removes it on exit.
