# Interactive Settings and experiments

`/config` opens a full-screen configuration editor. The older diagnostic listing remains available as `/config --text`; it is intentionally read-only and redacts provider environment values.

## Schema and categories

One schema (`Meringue::Config::Schema`) owns the supported paths, compatibility aliases, defaults, validation, category, editor type, description, sensitivity, and live/restart apply mode. The overlay is generated from that schema rather than keeping its own setting list.

Categories:

1. **Agent defaults** — separate future head/worker harness, Pi model, and Pi thinking defaults.
2. **Appearance** — theme and animation.
3. **Experiments** — registry-backed opt-in product capabilities.
4. **Harnesses** — provider commands, environment, arguments, Pi session directory, head names/timeouts, and Claude schema mode.
5. **Workspace** — managed root, provisioning limits, Git timeouts, shell/editor launchers, and terminal buffer.
6. **Safety** — worker command blacklist and predecessor-failure policy.
7. **Keybindings** — every action registered by `TUI::Keybindings`, including intentional unbinding with an empty list.
8. **Setup** — completion metadata plus **Run setup again**.

Advanced provider, workspace, and keybinding rows start collapsed. Select **Show advanced settings** or press `a` to reveal them. Every supported editable path is still reachable; internal compatibility keys are represented by their role-aware rows instead of duplicated.

## Interaction

- `↑` / `↓`: move through rows.
- `←` / `→`: change an enum/model selection; otherwise change category.
- `Tab` / `Shift-Tab`: change category.
- `PageUp` / `PageDown`, `Home` / `End`: move through long lists.
- `Space`: toggle a checkbox.
- `Enter`: change a selector, run an action, or open/apply a text editor.
- `Ctrl-S`: validate and submit one save transaction.
- `Esc`: cancel an editor; at the root, close a clean draft or show discard confirmation for a dirty draft.

`Esc` and `Ctrl-S` are fixed recovery keys inside Settings even when dashboard bindings are customized. Existing configured navigation bindings supplement the fixed keys.

Left-click selects a visible category or row. Clicking a checkbox toggles it. Save and Cancel are clickable in layouts that have room for the buttons. The wheel moves the visible row window. Empty space, chrome, right-click, release, and drag reports are inert.

Theme selection previews immediately in memory. Cancel/discard restores the original theme. No config or state write occurs until Save succeeds.

## Responsive layout

- 80 columns and wider: category rail plus detail pane.
- 46–79 columns: one-column category/list view.
- 32–45 columns: compact labels and reduced chrome; `Esc` remains visible.
- below 32×10: only a terminal-too-small message and `Esc cancel` are rendered.

Long categories use a selected-row window and show `N–M of T`. Exact command/model values are tail-clipped in rows but remain complete in the editor.

## Save transaction

Opening Settings captures the parsed file, effective values and sources, the file fingerprint, and the original theme. Save submits one non-head-proposable `SaveConfiguration` kernel command.

The config store:

1. acquires a config-specific cross-process lock;
2. rejects a stale fingerprint;
3. validates changed schema fields and cross-field constraints;
4. patches only schema-owned paths into the latest parsed document;
5. preserves unknown tables and keys;
6. writes a unique same-directory temporary file;
7. preserves an existing mode or creates a new file as `0600`;
8. flushes and fsyncs the file, atomically renames it, then fsyncs the directory where supported;
9. cleans temporary files after success or failure.

A successful command mirrors role-aware harness and Pi defaults into state, applies runtime-safe settings, and logs changed setting IDs only. Provider environment values never enter the log. Theme, keybindings, animation, role defaults, and experiments apply live. Provider process arguments/environment and workspace/launcher construction are saved but listed as restart-required.

Role serialization preserves old readers:

- equal head/worker values become one shared key with role overrides removed;
- different values retain/write a shared compatibility fallback and only role values that differ from it;
- old shared model, thinking, harness, argv, colorscheme, and workspace-keybinding aliases remain readable.

## Experiments registry

`Meringue::Experiments::Registry` is the only experiment list. Definitions carry an ID, config path, label, description/risk note, default, dependencies/conflicts, and live/restart mode. Both `/config` and first-run Setup derive their checkboxes from it.

The capability audit found only one capability that currently warrants an experiment:

```toml
[experiments]
github_support = false
```

Goal loops, non-Pi providers, focused workspaces, read-only workers, command blacklists, presentation preferences, and terminal launchers already have explicit activation or are core safety/preferences; adding a second opt-in gate would make them less clear.

### GitHub support

When enabled, Meringue may use bounded read-only `gh` lookups for exact issue/PR titles, delivery verification, branch discovery, and PR status refresh. Request/worker PR links can be associated, PR state participates in prune/reuse safety, and PR markers, pickers, hints, and browser actions are available.

When disabled:

- built-in head context contains no `gh` discovery commands or exact-GitHub-title rules;
- worker completion does not extract or verify PR URLs;
- reconciliation does not discover branches or refresh PR status;
- `/prs`, `Ctrl-B`, workspace PR actions, markers, and hints are hidden/gated with `Enable GitHub support in Settings → Experiments`;
- historical PR records remain stored;
- a previously verified `merged` fact still prevents unsafe branch reuse and permits prune;
- historical open/unknown records conservatively retain terminal work during prune, without external I/O, and the result explains how to re-enable refresh.

This is an integration gate, not a shell sandbox: user-directed worker commands and generic `after_command` gates are unchanged.

## Installation migration

The config carries `[settings].schema_version`. Migration runs before `State::Store` can create a new empty state file.

- Explicit experiment values always win.
- A pre-upgrade state file or onboarding marker migrates GitHub support to `true`.
- A genuinely new installation records GitHub support as `false`.
- Historical PR metadata and unknown config are not deleted.
- Onboarding version 1 remains valid and is not replayed.

## Setup uses the same overlay

First-run Setup is a curated `Settings::Draft` mode, not a second wizard. It presents Welcome → Theme → Head defaults → Worker defaults → Experiments → Review and reuses this pane's responsive geometry, editors, validation, theme preview, hit testing, and persistence result handling.

Finish sends the changed settings, explicit absent experiment defaults, and the completed onboarding outcome through one `SaveConfiguration` transaction. Automatic first-run skip saves only the skipped marker and explicit experiment defaults; manual `/setup` cancel writes nothing and preserves the existing marker. `/setup complete|skip` remain compatibility commands, and onboarding version 1 remains valid for existing users.

See [`onboarding.md`](onboarding.md) for keys, review/back behavior, first-run versus rerun cancellation, resize handling, and persistence failures.
