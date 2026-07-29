# Harness session model and thinking settings

Meringue records session settings in a harness-neutral `session_settings` object on each agent:

```json
{
  "model": {
    "provider": "openai",
    "id": "gpt-5.6-sol",
    "reference": "openai/gpt-5.6-sol",
    "name": "GPT-5.6 Sol"
  },
  "thinking_level": "xhigh",
  "availability": "available",
  "source": "live_session_state"
}
```

The focused agent workspace displays these values below the worker identity. Missing Pi values are shown as `unknown`; harnesses without this capability are shown as `unavailable`.

## Authoritative Pi discovery

For a live Pi RPC process, Meringue reads `model` and `thinkingLevel` from Pi's `get_state` response. The `model` value is Pi's full model object, not a Meringue config default or a copy of process spawn arguments. Pi's RPC event stream has lifecycle, message, queue, compaction, retry, and tool events, but no model/thinking-change event, so Meringue refreshes these values from session state rather than treating events as authoritative.

For a resumable process whose RPC transport is not available, Pi's persisted JSONL session is authoritative. Meringue walks the current session branch and reads Pi's `model_change` and `thinking_level_change` entries. An assistant message's provider/model is used only as a model fallback for older session files. If Pi persisted no authoritative thinking level, Meringue reports it as unknown rather than guessing.

Pi persists model and thinking changes in the session file, so values remain available after Meringue restarts. Reconciliation propagates values reported by new and active sessions into Meringue state. `/session` can explicitly refresh an existing active or resumable Pi session.

Codex, Claude Code, and other harnesses can implement the same generic client operations later. They currently return an explicit unsupported result; Meringue does not infer their settings from command-line arguments.

## Slash commands

```text
/session <agent_id>
/model <agent_id> <provider/model>
/thinking <agent_id> <off|minimal|low|medium|high|xhigh|max>
```

Examples:

```text
/session P1-I18-W1
/model P1-I18-W1 openai/gpt-5.6-sol
/thinking P1-I18-W1 xhigh
```

Completions offer agents with harness sessions, Pi's thinking levels, the default Pi model, and model references already observed in Meringue state.

Updates use Pi RPC `set_model` and `set_thinking_level`, then call `get_state` again and persist the effective values Pi reports. Thinking updates are checked against Pi's `get_available_thinking_levels`, so a level unsupported by the session's selected model is rejected instead of being silently clamped. Model ids must be provider-qualified and Pi rejects unknown models.

Settings cannot be changed while the target Pi turn is streaming or while another Meringue process owns its RPC transport. A settled persisted Pi session is resumed automatically before applying the update. Missing, killed, and non-Pi sessions return explicit errors.

## Scope and defaults

`/model` and `/thinking` change **only the targeted Pi session**. They do not edit `~/.meringue/config.toml`, Pi's global settings, Meringue's active harness, or future head/worker defaults.

New Pi sessions continue to use Meringue's configured model and thinking defaults unless the user explicitly changes the normal harness configuration. Switching a model can cause Pi to select an effective thinking level supported by that model; the command result and focused workspace always show Pi's resulting effective pair.
