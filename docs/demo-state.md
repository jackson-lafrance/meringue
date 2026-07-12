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

`fixtures/devpost_demo_state.json` contains the placeholder:

```txt
__MERINGUE_DEMO_PROJECT_ROOT__
```

At seed/reset time, Meringue replaces it with the nearest git root for the directory where the command is run. For the Devpost demo, run the command from the Meringue checkout so the seeded `P1` project points at the real local Meringue repo.
