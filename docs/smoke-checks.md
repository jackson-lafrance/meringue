# Smoke checks

The `scripts/` directory contains focused, dependency-free checks for behavior that is useful to
exercise manually but is awkward to launch from the Minitest suite. Run these from the repository
root. They use temporary state and fake harnesses unless a script says otherwise; they do not read
or write `~/.meringue`.

Most scripts can be run directly with Ruby:

```bash
ruby scripts/<name>.rb
```

The goal-loop check also needs the library load path:

```bash
ruby -Ilib scripts/goal_loop_smoke.rb
```

## Agent and kernel checks

| Script | Coverage |
| --- | --- |
| `head_session_smoke.rb` | Head harness session creation, result handling, and teardown. |
| `head_batch_apply_smoke.rb` | Exactly-once application of a multi-command head result and spawn collision handling. |
| `head_batch_issue_routing_smoke.rb` | Safe resolution of issue references within a head command batch. |
| `head_question_dedupe_smoke.rb` | Deduplication when a head asks the same question through multiple result channels. |
| `head_user_command_smoke.rb` | Head-proposed user commands, validation, logging, and destructive-command guardrails. |
| `question_answer_smoke.rb` | Answer routing from an open question through a fresh head and follow-up work. |
| `kernel_exactly_once_smoke.rb` | Exactly-once behavior for duplicate commands, questions, prompts, and reconciliation events. |
| `prompt_delivery_smoke.rb` | Deferring prompts for busy sessions and delivering them during reconciliation. |
| `network_aborted_settle_smoke.rb` | Classification of a Pi turn that ends with a transport error and no final response. |
| `reconcile_terminal_error_smoke.rb` | One-time logging and eventual pruning of unrecoverable sessions. |
| `prune_smoke.rb` | Retention rules for resolved, errored, active, and protected records. |

## TUI and goal-loop checks

| Script | Coverage |
| --- | --- |
| `agent_identity_smoke.rb` | Agent identity colors and harness marks across lifecycle statuses and themes. |
| `agent_tree_scroll_smoke.rb` | AgentTree keyboard/mouse scrolling, clamping, and selection reveal. |
| `chat_target_smoke.rb` | Selected chat-target styling and slash-command target clearing. |
| `delivery_pr_smoke.rb` | Delivery-PR hints and the unscoped open-PR picker. |
| `log_scope_smoke.rb` | AgentTree selection and log-pane subtree filtering. |
| `goal_loop_smoke.rb` | A complete goal loop with a real temporary git worktree and metric command. |

For automated coverage, use `rake test`. The checks in this document complement the suite; they are
not a second test runner and should remain small enough to run while investigating a focused area.
