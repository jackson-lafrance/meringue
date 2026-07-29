# TUI slice findings

Slice: `tui` (integration tests for TUI rendering and panes).
Owned paths: `test/integration/tui/**`, `test/support/tui_support.rb`, `test/findings/tui.md`,
plus deletion of `scripts/benchmark_tui_typing.rb`.

All tests are hermetic: no TTY, no raw mode, no network, no Pi processes, no writes outside
`Dir.mktmpdir`, and nothing touches `~/.meringue`. Every pane renders into an in-memory
`TUI::Canvas` or a `StringIO`, and assertions run against the produced buffer/lines.

## What is covered

| Area | File |
| --- | --- |
| Canvas diffing/blitting, clipping, ANSI emission, wide/unicode glyphs | `test/integration/tui/canvas_test.rb` |
| Colorschemes, semantic styles, deterministic agent palette | `test/integration/tui/style_test.rb` |
| Three-pane split, min sizes, resize, tiny dimensions, hit-testing | `test/integration/tui/layout_test.rb` |
| AgentTree rendering, glyphs, labels, nesting, truncation, selection | `test/integration/tui/agent_tree_pane_test.rb` |
| AgentTree navigation/selection vocabulary | `test/integration/tui/agent_tree_navigation_test.rb` |
| Composer wrapping, cursor, selection, hints, slash suggestions | `test/integration/tui/chat_pane_test.rb` |
| Log level/source styling, dedupe, caching, PR links, escapes | `test/integration/tui/logs_pane_test.rb` |
| Harness output normalization | `test/integration/tui/agent_output_test.rb` |
| Terminal Markdown rendering | `test/integration/tui/markdown_test.rb` |
| Selection geometry and clipboard transports | `test/integration/tui/selection_and_clipboard_test.rb` |
| Delivery PR presentation and link rendering | `test/integration/tui/delivery_pull_request_test.rb` |
| Key-to-action mapping, config overrides, conflicts | `test/integration/tui/keybindings_test.rb` |
| App wiring: snapshot in, no state mutation, no invented vocabulary | `test/integration/tui/app_wiring_test.rb` |
| Bounded typing throughput (replaces the retired benchmark script) | `test/integration/tui/typing_throughput_test.rb` |

## Deleted script

`scripts/benchmark_tui_typing.rb` was removed. Its assertions now live in
`test/integration/tui/typing_throughput_test.rb`:

- a cold frame plus 20 warm typing frames over a 150-entry Markdown log history;
- generous bounds (max warm frame < 1.0s, warm average < 0.25s, warm total < 5.0s, and warm
  average < 5x the cold frame) so the test catches "every keystroke re-renders all history"
  regressions rather than machine speed;
- the script's correctness check that a new durable log invalidates the presentation cache;
- an added deterministic check that a keystroke only changes the composer rows.

No other file referenced the script (checked `*.md`, `*.rb`, gemspec, Gemfile).

## Real behaviors recorded instead of "fixed"

No production code was changed. Where a test found surprising behavior, it asserts the current
actual behavior and is documented here.

1. `TUI::AgentOutput.normalize` raises on invalid UTF-8.
   `lib/meringue/tui/agent_output.rb` rescues only `ArgumentError`, and that rescue path calls
   `text.to_s.rstrip` on the same invalid bytes, which raises `Encoding::CompatibilityError`.
   A binary-encoded (`ASCII-8BIT`) string raises even earlier, from `String#tr`.
   `TUI::Markdown.sanitized_lines` sanitizes the same bytes correctly (it re-encodes with
   `invalid: :replace`), so the inconsistency is only in `AgentOutput`.
   Impact: a worker completion whose `details.last_assistant_text` contains invalid UTF-8 would
   raise while composing the logs pane. Suggested fix (not applied): re-encode in `normalize`
   the way `Markdown.sanitized_lines` does, and widen the rescue to `EncodingError`.
   Test: `TuiAgentOutputTest#test_invalid_utf8_currently_raises_instead_of_being_replaced`.

2. Markdown two-space hard line breaks are reflowed as soft breaks.
   `Markdown.sanitized_lines` applies `rstrip` to every row before parsing, so the trailing
   double space that marks a hard break is gone by the time `render` checks
   `line.end_with?("  ")`. A trailing backslash still produces a hard break.
   Impact: cosmetic only; agent prose using two-space breaks joins into one paragraph.
   Test: `TuiMarkdownTest#test_two_space_hard_break_is_currently_reflowed_but_backslash_breaks_split`.

3. `ChatPane#composer_char_index_at` shifts clicks right of the cursor by one column.
   This is intentional (the `_` cursor marker occupies a visual cell), but it means a click at
   visual column N maps to buffer index N-1 when the cursor sits to the left on the same row.
   Recorded so a future refactor does not "fix" it accidentally.
   Test: `TuiChatPaneTest#test_composer_char_index_maps_rows_and_columns_back_to_the_buffer`.

4. A wrapped composer row can be one cell wider than the pane content width.
   The cursor marker is appended after wrapping, so the row string may exceed the width by one
   character; `Canvas#write_segments` clips it, and the rendered frame stays rectangular.
   Covered indirectly by `TuiChatPaneTest#test_composer_lines_never_exceed_the_pane_width_after_canvas_clipping`
   and by the frame-rectangle assertions in `layout_test.rb`.

5. `Canvas` is character-indexed, not display-width aware.
   A CJK or emoji glyph occupies one cell, so a frame containing wide glyphs is rectangular in
   characters but not necessarily in terminal columns. Documented as current behavior in
   `TuiCanvasTest#test_wide_and_combining_characters_occupy_one_cell_each`.

6. `DeliveryPullRequest.status_label` returns `"unavailable"`, not `"not tracked"`, when an issue
   has no tracked PR. `"not tracked"` is only returned for a non-Hash presentation. The chat
   pane hint therefore reads `PR unavailable` for untracked workers.
   Test: `TuiChatPaneTest#test_untracked_delivery_pr_reports_its_state_instead_of_an_open_hint`.

7. `Style.configure!` mutates shared `StyleValue` constants in place.
   Any test that changes the colorscheme must restore it; `TUISupport.with_colorscheme` does this
   and every colorscheme test goes through it. Worth knowing for future test authors: a leaked
   colorscheme change would corrupt unrelated style assertions in the same process.

## Merge-overlap notes (resolved)

The keyboard-driven logs-pane selection work is on `main` and the merged suite is green against
it: no layout, selection, or app-wiring assertion needed changing. The notes below are kept as a
map of where TUI coverage touches selection code.


- Two other branches touch TUI/logs-pane code (a keyboard log-selection rebase). These tests were
  written against the code in this worktree. The most likely collision points are:
  - `lib/meringue/tui/layout.rb` logs selection helpers (`logs_text_position`,
    `logs_selection_text`, `draw_tail_content`, `tail_window`) — exercised by
    `layout_test.rb` (`test_logs_selection_is_reported_in_content_coordinates_and_extracted_as_text`,
    `test_selection_highlight_only_restyles_already_drawn_logs_cells`).
  - `lib/meringue/tui/selection.rb` geometry — exercised by `selection_and_clipboard_test.rb`.
  - `TUI::App` selection/keyboard handling — only lightly touched here
    (`app_wiring_test.rb` asserts composer editing, submit, and quit-key wiring).
  If the rebased branch adds keyboard-driven log selection, these tests should still pass; the
  assertions describe pane-scoped selection semantics rather than the input path that starts a
  selection. If a mouse-only assumption changes, the two layout tests above are the ones to review.
- `Rakefile` and `test/test_helper.rb` were created verbatim from the shared contract, so they are
  byte-identical across slices and safe to merge.
- This slice adds no gem dependencies. `test/support/tui_support.rb` is owned solely by this slice.

## How to run

```bash
rake test                                            # whole suite
ruby -Ilib -Itest test/integration/tui/layout_test.rb # one file
```
