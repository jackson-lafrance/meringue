# Meringue MVP Implementation Plan

`AGENTS.md` is the durable project context and architecture contract. This file is the current milestone plan for getting the first usable Meringue slices built.

If this file conflicts with `AGENTS.md`, follow `AGENTS.md` and update this plan in a separate, explicit change.

## Implementation order

Build Meringue in small, reviewable vertical slices. Agents should not try to build the full orchestration system in one pass.

### 1. Scaffold a Ruby CLI app

- Use the top-level Ruby namespace `Meringue`.
- Use `bin/meringue` as the executable entrypoint.
- Put application code under `lib/meringue`.
- Treat Meringue as an app, not a gem; do not add a gemspec or Gemfile during the MVP scaffold unless explicitly requested.
- Keep the scaffold stdlib-only and do not add a test framework or test directory.
- Prefer small modules/classes with clear ownership over one large script.
- Do not implement real Pi process management during the scaffold step.
- Empty placeholder files are acceptable only when the surrounding load path and module structure are clear.

### 2. Establish the initial project structure and state foundation

- Add folders for CLI, kernel, state, input routing, TUI, harness integration, heads, and fixtures.
- Define the JSON state shape before building features that mutate it.
- Add a fake/demo state fixture for TUI and kernel development.
- Use atomic JSON writes when implementing persistence, but the first scaffold may stub persistence behind a clear interface.

### 3. Build a TUI demo mode before real orchestration

- Render the three primary panes: AgentTree, Logs, and Chat/Input.
- The first TUI slice should load fake in-memory state or a fixture such as `fixtures/demo_state.json`.
- The TUI must not spawn Pi sessions, prompt real agents, or mutate production state in the first demo slice.
- Minimal controls are acceptable at first: render, accept simple input when practical, and support quitting cleanly.
- The TUI should render view models derived from kernel/state data rather than becoming the source of truth.

### 4. Implement input routing and slash command parsing

- Inputs beginning with `/` should bypass head agents and become structured kernel commands.
- Natural language should become a `SpawnHead` command.
- Slash commands and natural language should converge at the kernel command layer.
- Keep parsing separate from command validation and state mutation.

### 5. Implement kernel command validation with a fake harness/head path

- The kernel is the only code that mutates Meringue state.
- Start with deterministic fake head and fake harness implementations.
- Fake heads should return valid `HeadResult` JSON so the kernel can exercise `ApplyHeadResult` without Pi.
- Every accepted, rejected, or failed command should return a serializable command result and append a durable log entry.

### 6. Implement the simple head event loop

- User input should remain non-blocking from the product perspective, but the first code slice may use a simple synchronous loop if boundaries are clear.
- The first event loop should support: read input, route input, spawn a fake stateless head for natural language, apply the head result, update state/logs, and rerender.
- Do not introduce complex concurrency until the synchronous fake path works.

### 7. Add real Pi harness integration last

- Pi-specific code belongs only behind the harness client/process manager.
- The TUI and kernel should depend on generic harness operations, not direct Pi commands.
- Long-lived workers should eventually use `pi --mode rpc` over JSONL stdin/stdout.
- Short-lived heads may use Pi RPC or Pi JSON mode, but that choice must stay inside the Pi harness client.

## Recommended initial scaffold shape

```txt
bin/meringue
lib/meringue.rb
lib/meringue/version.rb
lib/meringue/cli.rb
lib/meringue/app.rb
lib/meringue/state/store.rb
lib/meringue/state/models.rb
lib/meringue/kernel/engine.rb
lib/meringue/kernel/commands.rb
lib/meringue/kernel/results.rb
lib/meringue/input/router.rb
lib/meringue/input/slash_command_parser.rb
lib/meringue/tui/app.rb
lib/meringue/tui/layout.rb
lib/meringue/tui/panes/chat_pane.rb
lib/meringue/tui/panes/agent_tree_pane.rb
lib/meringue/tui/panes/log_pane.rb
lib/meringue/harness/client.rb
lib/meringue/harness/fake_client.rb
lib/meringue/harness/pi_client.rb
lib/meringue/heads/runner.rb
lib/meringue/heads/fake_runner.rb
fixtures/demo_state.json
```

Early agents should prefer fake state, fake heads, and fake harness clients until the kernel, state model, and TUI boundaries are proven.

## Useful initial task prompts

### Scaffold the Ruby project

```txt
Read AGENTS.md and MVP_IMPLEMENTATION.md completely before making changes.

Task: Scaffold the initial Meringue Ruby CLI project only.

Follow the implementation order and recommended scaffold shape. Create `bin/meringue`, `lib/meringue.rb`, and the listed folders/files.

Constraints:
- Use the Ruby namespace `Meringue`.
- Make `bin/meringue` the executable entrypoint.
- Keep files minimal but loadable.
- Add tiny class/module stubs where useful.
- Do not implement real Pi integration.
- Do not build the TUI yet.
- Do not implement full kernel behavior yet.
- Prefer fake/stub interfaces where needed.

Definition of done:
- The project has a coherent folder structure.
- `ruby -Ilib bin/meringue` runs without load errors.
- The scaffold makes it obvious where CLI, kernel, state, input, TUI, harness, and heads code will live.
```

### Build the fake-state TUI demo

```txt
Read AGENTS.md and MVP_IMPLEMENTATION.md completely before making changes.

Task: Build the first TUI demo slice for Meringue.

Use the existing scaffold. Render the three primary panes:
- AgentTree
- Logs
- Chat/Input

Constraints:
- Use fake in-memory state or `fixtures/demo_state.json`.
- Do not spawn Pi.
- Do not prompt real agents.
- Do not mutate real user state.
- Keep TUI rendering separate from kernel/state ownership.
- The TUI should consume state/view-model data, not become the source of truth.

Definition of done:
- Running the app shows a recognizable three-pane Meringue layout.
- Fake projects, issues, workers, heads, and logs are visible.
- There is a clean quit path.
- Any input handling is minimal and clearly separated from rendering.
```

### Build the simple head-agent event loop with fake heads

```txt
Read AGENTS.md and MVP_IMPLEMENTATION.md completely before making changes.

Task: Implement the first simple head-agent event loop using fake heads.

Goal flow:
user input
-> input router
-> slash command parser OR SpawnHead command
-> fake stateless head for natural language
-> valid HeadResult JSON
-> kernel applies commands
-> state/logs update
-> TUI or CLI rerenders/summarizes state

Constraints:
- Use a fake head runner, not Pi.
- Keep natural language routing separate from slash command parsing.
- Keep parsing separate from kernel validation.
- The kernel must be the only layer that mutates state.
- A synchronous loop is acceptable for this first slice.
- Do not introduce complex concurrency yet.

Definition of done:
- Natural language input creates a fake head flow.
- Slash commands bypass the head path.
- Head results are validated before state mutation.
- Accepted/rejected/failed commands produce serializable command results.
- Logs are appended for important lifecycle events.
```
