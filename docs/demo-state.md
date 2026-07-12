# Devpost demo state

Meringue has a resettable, agent-enabled demo state for live demos.

Unlike `bin/meringue demo`, this mode still runs the normal interactive TUI with real prompt routing, heads, workers, harness selection, reconciliation, slash commands, and workspace allocation enabled.

## Start from the demo state

```bash
bin/meringue tui --demo-state
```

This uses:

```txt
~/.meringue/devpost-demo-state.json
```

If the file does not exist yet, Meringue seeds it from `fixtures/devpost_demo_state.json` before opening the TUI.

The seeded state preloads:

- `P1` Meringue, with self-hosting receipt work.
- `P2` `.config`, with safe high-level receipt work from recent local configuration changes.

It intentionally does not preload SimplyLift, so the demo can still show Meringue discovering/registering another project during the live flow.

## Reset before a new recording or live walkthrough

```bash
bin/meringue tui --reset-demo-state
```

This rewrites the demo state file from the fixture and then opens the full TUI.

To reset without opening the TUI:

```bash
bin/meringue reset-demo-state
```

## Use a temporary/custom demo state path

```bash
bin/meringue tui --demo-state --state /tmp/meringue-devpost-demo.json
bin/meringue tui --reset-demo-state --state /tmp/meringue-devpost-demo.json
```

You can also set:

```bash
MERINGUE_DEMO_STATE_PATH=/tmp/meringue-devpost-demo.json bin/meringue tui --demo-state
```

## Fixture templating

`fixtures/devpost_demo_state.json` contains these placeholders:

```txt
__MERINGUE_DEMO_PROJECT_ROOT__
__MERINGUE_DEMO_CONFIG_ROOT__
```

At seed/reset time, Meringue replaces `__MERINGUE_DEMO_PROJECT_ROOT__` with the nearest git root for the directory where the command is run. For the Devpost demo, run the command from the Meringue checkout so the seeded `P1` project points at the real local Meringue repo.

`__MERINGUE_DEMO_CONFIG_ROOT__` defaults to `~/.config`. Override it with:

```bash
MERINGUE_DEMO_CONFIG_ROOT=/path/to/config bin/meringue tui --reset-demo-state
```
