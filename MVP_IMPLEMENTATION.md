# Meringue MVP Parallel + Headless Pi Implementation Plan

`AGENTS.md` is the durable project context and architecture contract. This file is the current milestone plan for getting the first usable Meringue pieces built quickly.

If this file conflicts with `AGENTS.md`, follow `AGENTS.md` and update this plan in a separate, explicit change.

## Strategy: headless Pi first, parallel slices around it

The MVP should no longer be built as one strict step-by-step chain. The first merge target is a **headless Pi setup**: a manually runnable Ruby path that can start Pi without the TUI, communicate through the harness boundary, and prove Meringue can drive real Pi sessions.

In parallel, split the rest of the app into independent, manually runnable Ruby slices that separate agents can build in separate branches and worktrees. The fake paths are development helpers so state, input routing, kernel validation, and rendering do not block on each other. They are not a requirement to finish before the headless Pi work lands.

The goal for each slice is:

1. Prove the local behavior works on its own.
2. For headless Pi work, prove real Pi process/RPC behavior behind the harness/head boundary.
3. Keep the boundary clean enough that another agent can wire it into the full app later.
4. Avoid polishing details that are not needed for the slice's standalone demo.

This means a slice can be "ugly but useful" as long as it:

- runs with one clear `ruby -Ilib ...` command,
- stays inside the correct architectural boundary,
- uses serializable Ruby hashes/arrays/strings/numbers/booleans/nil at its seams,
- avoids mutating orchestration state outside the kernel,
- implements real Pi behavior inside the headless Pi/harness/head slice when that is the task,
- uses fake/stub behavior in non-Pi slices only to keep parallel work unblocked,
- documents what is real, fake, stubbed, or deferred.

The later integration pass will clean up naming mismatches, shared loaders, UX polish, concurrency, and cross-slice wiring. Real Pi behavior should still stay isolated behind harness/head interfaces while that integration happens.

## First merge target: headless Pi setup

Prioritize the headless Pi setup before the polished TUI and before the fake end-to-end loop. This is the first thing we want to prove and merge.

The headless Pi setup should demonstrate:

```txt
manual Ruby script
-> Pi harness client
-> pi --mode rpc or another headless Pi mode chosen inside the Pi client
-> get/capture Pi session metadata
-> optionally send one prompt
-> read structured events/final output
-> return serializable Meringue session/head result data
```

Important constraints:

- Pi-specific process/RPC code belongs in `lib/meringue/harness/pi_client.rb` and optional Pi-specific head runner files, not in the TUI or kernel command parser.
- A smoke script may start a real Pi session. That is expected for this first merge target.
- A smoke script should use a harmless prompt and a safe cwd. Prefer a temp/demo directory or clearly documented cwd so the smoke run does not accidentally edit the project.
- If the first headless Pi version can only prove `get_state`, session naming, process lifecycle, or event parsing, that is still useful. It does not need the full orchestration flow yet.
- If the first Pi head run asks Pi to return `HeadResult` JSON, it may print a validation error and raw output when Pi returns invalid JSON. That is a useful smoke result, not a reason to overbuild.

Not required for the first headless Pi merge:

- Polished TUI rendering.
- Full kernel integration.
- Worker worktree allocation.
- Perfect streaming support.
- Session recovery/reconciliation.
- Applying returned kernel commands to persistent state.

## Parallel agent workflow

Every implementation agent should work like this:

1. Read `AGENTS.md` and this file completely.
2. Create a fresh task branch in its own worktree, preferably:
   `../meringue-worktrees/<short-task-name>`.
3. Work on one slice only.
4. Add or update reusable code under `lib/meringue/...`.
5. Add a tiny manual smoke script under `scripts/<slice>_smoke.rb` when useful.
6. Run the slice directly with a command such as:
   `ruby -Ilib scripts/<slice>_smoke.rb`.
7. In the final response, report the exact command that was run and what it proved.

Avoid editing shared loader files such as `lib/meringue.rb` unless the slice truly needs it. A smoke script may require the slice files directly so multiple agents do not all conflict on the same root require list. The integration pass can normalize root requires later.

Smoke scripts are not the final product. They are disposable proof harnesses that let each task move without waiting for the full CLI/TUI/kernel loop.

## Current baseline

The repository already has the initial Ruby scaffold shape:

```txt
bin/meringue
lib/meringue.rb
lib/meringue/version.rb
lib/meringue/cli.rb
lib/meringue/app.rb
lib/meringue/state/models.rb
lib/meringue/state/store.rb
lib/meringue/kernel/engine.rb
lib/meringue/kernel/commands.rb
lib/meringue/kernel/results.rb
lib/meringue/input/router.rb
lib/meringue/input/slash_command_parser.rb
lib/meringue/workspace/manager.rb
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

Parallel tasks should extend this structure instead of replacing it. A task may add new files such as `lib/meringue/heads/pi_runner.rb` or `scripts/pi_headless_smoke.rb` when the track needs them.

## Shared contracts to preserve

These boundaries matter more than perfect implementation details:

- **State** owns JSON loading/saving helpers and the canonical object shape.
- **Kernel** is the only layer that mutates Meringue orchestration state.
- **Input routing** turns user text into structured command objects; it does not mutate state.
- **Heads** return `HeadResult` hashes/JSON only; they do not edit Meringue state or project files.
- **Harness clients** hide Pi/fake process behavior behind generic operations.
- **Pi client/head runner** may implement real Pi behavior, but Pi details must not leak into kernel/input/TUI code.
- **Workspace manager** allocates worker workspace metadata; TUI, heads, and harness clients do not create worktrees directly.
- **TUI** renders state/view models; it does not own source-of-truth state.
- **Headless Pi smoke scripts** may start/stop real Pi sessions, but they should not become a second kernel or a TUI data source.

When a non-Pi slice needs another slice that is not ready, use a small local fake or fixture. Do not reach across boundaries just to make the demo work.

## Good-enough rule for parallel work

A slice does **not** need to be perfect. For the MVP parallel phase, the bar is:

- It runs manually.
- It demonstrates the core behavior.
- It returns or prints understandable structured output.
- It leaves clear notes about what is fake or deferred.
- It is small enough to merge or rewrite during integration.

Examples of acceptable shortcuts:

- Synchronous loops instead of concurrency.
- Hard-coded fixture paths instead of config systems.
- Deterministic fake head responses in non-Pi slices.
- Simple terminal printing instead of polished TUI rendering.
- Dry-run workspace metadata instead of real `git worktree` commands.
- Fake harness events in non-harness slices.
- A minimal real Pi smoke that only proves process startup, `get_state`, session naming, or event parsing.

Examples of shortcuts that are **not** acceptable:

- TUI code directly mutating persisted state.
- Head code directly writing to Meringue JSON state.
- Pi-specific behavior leaking into kernel/input/TUI code.
- Worker workspace creation happening inside the harness client.
- New lifecycle statuses, question statuses, or log levels not defined in `AGENTS.md`.

## Parallel task tracks

The tracks below can run at the same time. Each should have its own branch/worktree and a direct smoke command. Track H is the preferred first merge target.

### Track A: State store and JSON shape

Owns:

- `lib/meringue/state/models.rb`
- `lib/meringue/state/store.rb`
- `fixtures/demo_state.json` only if the fixture needs schema updates
- optional `scripts/state_smoke.rb`

Standalone goal:

```bash
ruby -Ilib scripts/state_smoke.rb
```

Definition of done:

- Can create an empty state hash with the required top-level keys.
- Can load JSON state from a path.
- Can write JSON state atomically to a caller-provided path.
- Can use a temp/demo path for smoke runs instead of touching `~/.meringue/state.json` by default.
- Preserves ISO8601 timestamps and the statuses/log levels from `AGENTS.md`.

Not required yet:

- Full migration system.
- Perfect schema validation.
- Locking for multiple processes.

### Track B: Kernel command engine and results

Owns:

- `lib/meringue/kernel/engine.rb`
- `lib/meringue/kernel/commands.rb`
- `lib/meringue/kernel/results.rb`
- optional `scripts/kernel_smoke.rb`

Standalone goal:

```bash
ruby -Ilib scripts/kernel_smoke.rb
```

Definition of done:

- Accepts structured command hashes or command objects.
- Implements a minimal useful subset such as `AddProject`, `CreateIssue`, `AskQuestion`, `AnswerQuestion`, and `SpawnWorker` state metadata that can later receive a harness session reference.
- Validates enough input to reject obviously bad commands without mutation.
- Returns serializable `KernelCommandResult` hashes.
- Appends concise log entries for accepted/rejected/failed commands.
- Keeps all state mutation inside the kernel engine.

Not required yet:

- Every command in `AGENTS.md`.
- Direct Pi process management inside the kernel.
- Real workspace creation.
- Complex transaction handling.

### Track C: Simple head runner and HeadResult contract

Owns:

- `lib/meringue/heads/runner.rb`
- `lib/meringue/heads/fake_runner.rb`
- optional `lib/meringue/heads/pi_runner.rb` if sharing a generic head interface with Track H
- optional `scripts/head_smoke.rb`

Standalone goal:

```bash
ruby -Ilib scripts/head_smoke.rb "create an issue to render the logs pane"
```

Definition of done:

- Given a user message and a simple state snapshot, returns a valid `HeadResult` hash:

```json
{
  "title": "Short display title",
  "summary": "Short user-visible summary",
  "commands": [],
  "questions": []
}
```

- Produces deterministic command proposals for demo messages when using the fake/simple runner.
- Can propose at least one useful command path, such as create issue plus spawn worker.
- Can emit a clarifying question for intentionally ambiguous input.
- Does not mutate state.

Not required yet:

- Smart project selection.
- Perfect natural-language understanding.
- Applying the returned commands to state.

### Track D: Input router and slash command parser

Owns:

- `lib/meringue/input/router.rb`
- `lib/meringue/input/slash_command_parser.rb`
- optional `scripts/input_smoke.rb`

Standalone goal:

```bash
ruby -Ilib scripts/input_smoke.rb
```

Definition of done:

- Text beginning with `/` routes to slash command parsing.
- Plain natural language routes to a `SpawnHead` command.
- Parses the MVP slash commands well enough for manual demos:
  - `/project add <path> [name]`
  - `/issue create <project_id> "<title>" ["description"]`
  - `/worker spawn <issue_id> "<prompt>"`
  - `/prompt <agent_id> "<message>"`
  - `/kill <agent_or_issue_id>`
  - `/tree`
  - `/state`
  - `/questions`
  - `/answer <question_id> "<answer>"`
- Returns structured command hashes and parse errors; does not mutate state.

Not required yet:

- Perfect shell quoting edge cases.
- Autocomplete.
- Rich command help UI.

### Track E: TUI/static renderer demo

Owns:

- `lib/meringue/tui/app.rb`
- `lib/meringue/tui/layout.rb`
- `lib/meringue/tui/panes/chat_pane.rb`
- `lib/meringue/tui/panes/agent_tree_pane.rb`
- `lib/meringue/tui/panes/log_pane.rb`
- optional `scripts/tui_smoke.rb`

Standalone goal:

```bash
ruby -Ilib scripts/tui_smoke.rb
```

Definition of done:

- Reads `fixtures/demo_state.json` or a local fake state hash.
- Renders recognizable AgentTree, Logs, and Chat/Input sections.
- Can be static output or a very small interactive loop with a clean quit path.
- Treats the fixture/state as read-only.
- Keeps rendering separate from kernel state mutation.

Not required yet:

- Perfect screen blitting.
- Mouse support.
- Full keyboard navigation.
- Jumping into harness sessions.

### Track F: Workspace manager dry-run allocation

Owns:

- `lib/meringue/workspace/manager.rb`
- optional `scripts/workspace_smoke.rb`

Standalone goal:

```bash
ruby -Ilib scripts/workspace_smoke.rb
```

Definition of done:

- Given project/issue/worker IDs, returns workspace metadata for an agent record:
  - `workspace_path`
  - `workspace_strategy`
  - `workspace_branch`
- Defaults to dry-run metadata so smoke runs do not mutate git state.
- Keeps actual `git worktree` execution behind an explicit method or flag.
- Uses predictable Meringue branch naming such as `meringue/P1-I2-W1`.

Not required yet:

- Full cleanup/pruning.
- Handling every git failure mode.
- Creating real worktrees by default.

### Track G: Fake harness client and worker lifecycle helper

Owns:

- `lib/meringue/harness/client.rb`
- `lib/meringue/harness/fake_client.rb`
- optional `scripts/harness_smoke.rb`

Standalone goal:

```bash
ruby -Ilib scripts/harness_smoke.rb
```

Definition of done:

- Exposes generic operations shaped like:
  - `spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:)`
  - `prompt_session(session_ref, prompt, mode:)`
  - `abort_session(session_ref)`
  - `kill_session(session_ref)`
  - `get_state(session_ref)`
  - `read_events(session_ref)`
  - `attach_session(session_ref)`
- Fake client returns serializable session references and lifecycle events.
- Supports enough fake behavior for kernel and TUI demos to show worker activity.
- Does not contain Pi-specific assumptions.

Not required yet:

- Real process management.
- Streaming tokens.
- Persistent session reconnection.

### Track H: Headless Pi harness and Pi head runner setup

This is the preferred first merge target.

Owns:

- `lib/meringue/harness/pi_client.rb`
- optional `lib/meringue/heads/pi_runner.rb`
- optional `scripts/pi_headless_smoke.rb`
- optional `scripts/pi_head_smoke.rb`

Standalone goals:

```bash
ruby -Ilib scripts/pi_headless_smoke.rb
ruby -Ilib scripts/pi_head_smoke.rb "create one issue and one worker for this request"
```

Definition of done:

- Is developed behind the same generic harness client boundary as the fake client.
- Starts `pi --mode rpc` or another headless Pi mode only inside Pi harness/head code.
- Communicates over JSONL stdin/stdout when using RPC mode.
- Can request Pi state and capture `sessionId`/`sessionFile` when available.
- Can label sessions with `set_session_name` when available.
- Can send one prompt from a manual script when safe to do so.
- Can read structured events and/or final output from Pi.
- If implementing a Pi head runner, asks Pi for `HeadResult` JSON and validates the returned shape before printing it.
- Returns serializable session references and head result data for later kernel integration.
- Documents exact assumptions about the Pi commands/messages it sends and receives.

Not required yet:

- Wiring Pi into the main kernel loop.
- Applying returned commands to persistent state.
- Perfect streaming support.
- Full recovery/reconcile behavior.
- TUI integration.

Important: this track is real Pi behavior by design. Keep it headless and isolated, but do not defer it behind fake harness work.

## Integration pass after parallel slices

After the headless Pi setup lands and several independent slices work on their own, create a dedicated integration branch/worktree. The integration agent should merge and connect slices in this order:

1. Headless Pi harness/session reference and, if available, Pi head runner output validation.
2. State models/store.
3. Kernel commands/results using the state store.
4. Input router into kernel command execution.
5. Pi head runner into `SpawnHead`/`ApplyHeadResult` for natural-language input.
6. Workspace manager into `SpawnWorker` state metadata.
7. Fake harness only as a local fallback/smoke helper where useful.
8. TUI renderer consuming the integrated state/view model.
9. Long-lived Pi worker sessions behind the same generic harness interface.

Integration goals:

- Prefer small adapter changes over rewriting working slices.
- Keep smoke scripts until the integrated app replaces their usefulness.
- Resolve naming/shape mismatches at boundaries.
- Preserve the rule that the kernel owns orchestration state mutation.
- Keep Pi-specific behavior behind harness/head interfaces.
- Do not polish the UI before the headless CLI flow works.

First integrated headless flow target:

```txt
user input
-> input router
-> slash command parser OR SpawnHead command
-> Pi head runner for natural language
-> HeadResult commands/questions
-> kernel validation/application
-> JSON state/log update
-> CLI summary rerender
```

Slash commands should still bypass heads and go straight to kernel command validation. The TUI can attach later once this headless flow is reliable.

## Copy/paste task prompt template

Use this template when launching a parallel implementation agent:

```txt
Read AGENTS.md and MVP_IMPLEMENTATION.md completely before making changes.

Task: Work on Track <letter/name> only.

Create or use a fresh task branch and worktree for this track. Do not edit a shared checkout.

Goal:
- Build the smallest standalone Ruby implementation of this track.
- Add a manual smoke script under scripts/<slice>_smoke.rb if useful.
- The slice should run with ruby -Ilib scripts/<slice>_smoke.rb.

Constraints:
- Stay inside this track's owned files unless a tiny adjacent change is required.
- Implement real Pi behavior only for Track H/headless Pi work or when the task explicitly says to wire Pi behind the harness layer.
- Do not mutate orchestration state outside the kernel.
- Prefer serializable hashes at boundaries.
- Fake or stub dependencies from other tracks when that keeps non-Pi work unblocked.
- Do not chase polish; make it work independently and document what is deferred.

Definition of done:
- The smoke command runs.
- The output proves the slice's core behavior.
- The final response includes the command run, result, changed files, and what integration assumptions remain.
```

## Recommended next smallest integration milestone

Once Track H plus the basic state/kernel/input slices have smoke scripts, wire a temporary headless CLI loop that demonstrates:

```txt
natural language input -> real Pi head runner -> HeadResult JSON -> kernel applies result -> logs/state summary prints
slash command input -> parser -> kernel applies command -> logs/state summary prints
```

This can still be a manually run `.rb` file. It does not need a polished TUI or full worker concurrency yet.
