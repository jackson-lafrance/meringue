# Interactive Settings and experiments

`/config` opens a full-screen configuration editor. The older diagnostic listing remains available as `/config --text`; it is intentionally read-only and redacts provider environment values.

The Settings header keeps a small reminder in view: **“Not sure what to change? Ask your agent for help.”** On narrower terminals it shortens to “Need help? Ask your agent.”, while the first-run setup card stays focused on its welcome and step guidance.

## Schema and categories

One schema (`Meringue::Config::Schema`) owns the supported paths, compatibility aliases, defaults, validation, category, editor type, description, sensitivity, and live/restart apply mode. The overlay is generated from that schema rather than keeping its own setting list.

Categories:

1. **Agent defaults** — separate future head/worker harness, model, and harness-translated thinking defaults.
2. **Appearance** — theme and animation.
3. **Experiments** — registry-backed opt-in product capabilities.
4. **Harnesses** — provider commands, environment, arguments, Pi session directory, head names/timeouts, and Claude schema mode.
5. **Workspace** — managed root, provisioning limits, Git timeouts, shell/editor launchers, and terminal buffer.
6. **Alternate backend** — the two pluggable axes: the git backend that provisions isolated mutable workspaces, and the code-hosting frontend that answers pull-request questions. Both default to the built-in GitHub-backed pair; both `command` selections are documented extension points.
7. **Safety** — worker command blacklist and predecessor-failure policy.
8. **Keybindings** — every action registered by `TUI::Keybindings`, including intentional unbinding with an empty list. These rows are shown directly; they are not Advanced settings.

Advanced provider, workspace, and keybinding rows start collapsed **inside the category that owns them**. Each category shows its exact hidden count in the category rail and in a **Show advanced settings (N)** row; selecting it or pressing `a` reveals only that category's rows. The row keeps its place once open, reading **Hide advanced settings (N)** above the rows it revealed, so the control that opened them is the one that puts them away; the footer names the `A` key wherever the category has advanced rows and the line has room. Other categories keep their own advanced rows collapsed, so the reveal count never describes settings somewhere else. Every supported editable path is still reachable; internal compatibility keys are represented by their role-aware rows instead of duplicated.

## Interaction

- `↑` / `↓`: move through rows.
- `Shift-↑` / `Shift-↓`: jump to the previous or next category section. The jump lands on the last row of the previous section or the first row of the next section; at the first or last section it stays put.
- `←` / `→`: change the focused setting when the control supports it; otherwise do nothing. They never move focus or change category.
- Keybindings are shown directly in their category; they are not hidden behind the Advanced settings disclosure.

`/config` does not include the Setup category; setup metadata and the Run setup again action remain available through the dedicated `/setup` flow.
- `Tab` / `Shift-Tab`: change category.
- `PageUp` / `PageDown`, `Home` / `End`: move through long lists.
- `Space`: toggle a checkbox.
- `Enter`: change a selector, run an action, or open/apply an editor. On a Keybindings row, it enters dedicated key capture; the next keyboard key replaces that binding.
- `Ctrl-S`: validate and submit one save transaction.
- `Esc`: cancel an editor; at the root, close a clean draft or show discard confirmation for a dirty draft.

`Esc` and `Ctrl-S` are fixed recovery keys inside Settings even when dashboard bindings are customized. Existing configured navigation bindings supplement the fixed keys.

Left-click selects a visible category or row. Clicking a checkbox toggles it. Save and Cancel are clickable in layouts that have room for the buttons. The wheel moves the visible row window. Empty space, chrome, right-click, release, and drag reports are inert. While key capture is active, mouse events and invalid multi-character input stay inside the capture view and never move or activate another row; `Esc` cancels, while `Backspace` or `Delete` clears/unbinds.

Theme selection previews immediately in memory. Cancel/discard restores the original theme. No config or state write occurs until Save succeeds. Command and list fields begin with their current effective values, including environment overrides and compatibility fallbacks, rather than empty placeholders.

## Responsive layout

- 80 columns and wider: category rail plus detail pane.
- 46–79 columns: one-column category/list view.
- 32–45 columns: compact labels and reduced chrome; `Esc` remains visible.
- below 32×10: only a terminal-too-small message and `Esc cancel` are rendered.

Long categories use a selected-row window and show `N–M of T`. Exact command/model values are tail-clipped in rows but remain complete in the editor.

## Harness migration and split defaults

The `agent_defaults_mode` experiment is registry-backed and defaults to `role-specific`, which makes role-specific model/thinking rows authoritative for their role. In `shared` mode both roles read and write one value, so a role-named write updates both rather than storing a role value the reader would ignore. Switching a harness re-resolves incompatible future thinking values for the affected shared or role-specific defaults in the same config transaction. Model references remain shape-validated rather than catalog-gated, so exact unverified references survive a stale or unavailable catalog. Existing sessions keep their stored effective settings.

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

A successful command mirrors role-aware harness, model, and thinking defaults into state, applies runtime-safe settings, and logs changed setting IDs only. Provider environment values never enter the log. Theme, keybindings, animation, role defaults, and experiments apply live. Provider process arguments/environment and workspace/launcher construction are saved but listed as restart-required.

Role serialization preserves old readers:

- equal head/worker values become one shared key with role overrides removed;
- different values retain/write a shared compatibility fallback and only role values that differ from it;
- old shared model, thinking, harness, argv, colorscheme, and workspace-keybinding aliases remain readable.

## Experiments registry

`Meringue::Experiments::Registry` is the only experiment list. Definitions carry an ID, config path, label, description/risk note, default, dependencies/conflicts, and live/restart mode. Both `/config` and first-run Setup derive their checkboxes from it.

The current experiment definitions are:

```toml
[experiments]
agent_defaults_mode = "role-specific"   # shared | role-specific | guided
# worker_spawning_guidance_prompt is shown only in guided mode
```

GitHub support is not an experiment: it is default behavior, selected through the frontend axis of the Alternate backend category. See [GitHub support and the frontend axis](#github-support-and-the-frontend-axis) below.

`agent_defaults_mode` selects one of three arrangements for future model and reasoning defaults, and defaults to `role-specific`:

| Mode | Shown as | Behavior |
| --- | --- | --- |
| `shared` | Shared | One model and one reasoning level for every future head and worker. Naming a role still writes the single shared value, and the pickers drop their Head/Worker tabs. |
| `role-specific` | By role | Heads and workers keep independent values. `/model head …` and `/model worker …` write only that role. |
| `guided` | Guided | As `role-specific`, and heads choose each worker's model and reasoning from a prompt you write. |

The guided selection prompt is edited inline in the Experiments section of both Settings and Setup, or through `/worker guide "..."`. Its row appears only in guided mode and its saved value is retained when you switch away. Guided heads receive neither configured nor effective worker model/reasoning defaults, and guided `SpawnWorker` commands must set both selections explicitly.

Role *harnesses* are independent of this mode: `/harness head …` and `/harness worker …` always apply per role, so the harness picker keeps its Head/Worker tabs in every mode.

Goal loops, harness selection, focused workspaces, read-only workers, command blacklists, presentation preferences, and terminal launchers already have explicit activation or are core safety/preferences.

### GitHub support and the frontend axis

GitHub support is on by default. When the built-in GitHub frontend is selected (`[forge] frontend = "github"`, the default), Meringue may use bounded read-only `gh` lookups for exact issue/PR titles, delivery verification, branch discovery, and PR status refresh. Request/worker PR links can be associated, PR state participates in prune/reuse safety, and PR markers, pickers, hints, and browser actions are available.

While the GitHub frontend is selected, the Alternate backend category also provides **Test GitHub access**; the action is completely absent while an alternate frontend is selected. This non-persistent action resolves the current checkout's `origin` remote and checks the minimum supported workflow access: `gh auth status --hostname github.com`, followed by `gh repo view OWNER/REPO --json nameWithOwner`. Both commands are non-interactive, share a short timeout, and are read-only; no GitHub resource can be created, edited, closed, commented on, or merged. `/github test` runs the same kernel command. The UI identifies successful access, an unavailable CLI/service, missing authentication, denied repository access, a timeout, or a malformed/non-GitHub remote, and retrying the action does not change GitHub.

While an alternate frontend is selected (`[forge] frontend = "command"`):

- built-in head context contains no `gh` discovery commands or exact-GitHub-title rules;
- worker completion does not extract or verify PR URLs;
- reconciliation does not discover branches or refresh PR status;
- `/prs`, `Ctrl-B`, workspace PR actions, markers, and hints are hidden/gated with a message pointing at Settings → Alternate backend;
- historical PR records remain stored;
- a previously verified `merged` fact still prevents unsafe branch reuse and permits prune;
- historical open/unknown records conservatively retain terminal work during prune, without external I/O, and the result explains how to restore the GitHub frontend.

A `command` frontend is an extension point, not a shipped implementation: it fails closed (no lookups, no GitHub UI) until an adapter exists. Embedding applications may instead inject their own frontend object implementing the documented forge client contract; see [`forge-frontends.md`](forge-frontends.md).

This is an integration gate, not a shell sandbox: user-directed worker commands and generic `after_command` gates are unchanged.

## Installation migration

The config carries `[settings].schema_version`. Migration runs before `State::Store` can create a new empty state file.

- Schema 3 deletes a persisted `experiments.github_support` key: GitHub support became default behavior, so a setup that saved `true` keeps it (it is now the default) and there is no experiment checkbox to restore. Other saved keys are untouched.
- Historical PR metadata and unknown config are not deleted.
- The `[forge]` and `[version_control]` selections default to the built-in GitHub-backed pair when absent.
- Onboarding version 1 remains valid and is not replayed.

## Setup uses the same overlay

First-run Setup is a curated `Settings::Draft` mode, not a second persistence implementation. It presents a centered, welcoming Welcome → Harness → Theme → Alternate backend → Meringue Xtras → Done flow, asks for one harness and applies it to both roles, offers a short Preferred editor list (`vim`, `nvim`, `emacs`, `cursor`, `code`, or **Custom**), confirms the default git backend and GitHub frontend (alternates plug in through the same step), asks for no model or reasoning at all, and will not advance past the Harness step until one is chosen with one dynamic step indicator, contextual Enter/picker controls, and a restrained optional welcome animation. The dashboard status bar always uses its built-in layout; it is not a Setup/Settings customization surface. Every page has one centered Next/Complete action, while Backspace/Delete/Shift-Tab retain backwards navigation. Meringue Xtras ends the flow with Complete. Setup reuses the schema, editors, validation, theme/status previews, hit testing, and persistence result handling without inheriting the dense advanced-settings presentation.

Complete sends the changed settings, explicit absent experiment defaults, and the completed onboarding outcome through one `SaveConfiguration` transaction. Automatic first-run skip saves only the skipped marker and explicit experiment defaults; manual `/setup` cancel writes nothing and preserves the existing marker. `/setup complete|skip` remain compatibility commands, and onboarding version 1 remains valid for existing users.

See [`onboarding.md`](onboarding.md) for keys, navigation/back behavior, first-run versus rerun cancellation, resize handling, and persistence failures.
