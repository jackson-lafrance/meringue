# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      private

      # Durable protection is deliberately an agent property rather than a PR property: it keeps
      # an agent and the issue/project needed to reach it visible even when no delivery exists.
      def set_agent_prune_protection(command_id, command_type, payload)
        agent_id = value_at(payload, "agent_id", "AgentID", "agentId", "target_id", "TargetID", "targetId")
        protected_value = value_at(payload, "protected", "protect", "enabled")
        return rejected_result(command_id, command_type, "Agent id is required.", ["agent_id_required"]) if blank?(agent_id)
        return rejected_result(command_id, command_type, "Protection must be true or false.", ["protected_boolean_required"]) unless [true, false].include?(protected_value)

        state = normalized_state
        agent = find_agent(state, agent_id)
        return rejected_result(command_id, command_type, "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless agent

        now = timestamp
        agent["prune_protected"] = protected_value
        agent["updated_at"] = now
        action = protected_value ? "protected from" : "unprotected for"
        message = "Agent #{agent.fetch("id")} is now #{action} pruning."
        log_ids = append_log(
          state, source_type: "kernel", source_id: agent.fetch("id"), level: "info", message: message,
          details: { "agent_id" => agent.fetch("id"), "prune_protected" => protected_value }
        )
        touch_state!(state, now)
        store.save(state)
        accepted_result(command_id, command_type, agent.fetch("id"), message, agent, log_ids)
      end
    end
  end
end
