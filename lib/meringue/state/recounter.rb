# frozen_string_literal: true

module Meringue
  module State
    # Renumbers user-facing AgentTree records while preserving their relationships.
    # Opaque runtime identifiers (harness sessions, PIDs, workspaces, branches) and
    # append-only log/message IDs intentionally remain unchanged.
    module Recounter
      OPAQUE_ID_KEYS = %w[
        command_id event_id harness_session_id log_entry_ids message_id next_message_id
        pid session_id tool_call_id
      ].freeze

      module_function

      def recount!(state)
        project_map = sequential_map(state.fetch("projects"), /^P(\d+)$/) { |number, _record| "P#{number}" }
        issue_map = issue_id_map(state, project_map)
        worker_map = worker_id_map(state, issue_map)
        question_map = sequential_map(state.fetch("questions"), /^Q(\d+)$/) { |number, _record| "Q#{number}" }
        id_map = project_map.merge(issue_map).merge(worker_map).merge(question_map)

        rewrite_primary_ids!(state, project_map, issue_map, worker_map, question_map)
        rewrite_record_references!(state, id_map)
        clean_agent_relationships!(state)
        rebuild_issue_agent_ids!(state)
        reset_counters!(state)
        validate_integrity!(state)

        {
          "project_ids" => changed_entries(project_map),
          "issue_ids" => changed_entries(issue_map),
          "worker_ids" => changed_entries(worker_map),
          "question_ids" => changed_entries(question_map)
        }
      end

      def sequential_map(records, pattern)
        sorted_records(records, pattern).each_with_index.to_h do |record, index|
          [record.fetch("id"), yield(index + 1, record)]
        end
      end

      def issue_id_map(state, project_map)
        state.fetch("projects").flat_map do |project|
          old_project_id = project.fetch("id")
          new_project_id = project_map.fetch(old_project_id)
          issues = state.fetch("issues").select { |issue| issue.fetch("project_id", nil) == old_project_id }
          sorted_records(issues, /^#{Regexp.escape(old_project_id)}-I(\d+)$/).each_with_index.map do |issue, index|
            [issue.fetch("id"), "#{new_project_id}-I#{index + 1}"]
          end
        end.to_h
      end

      def worker_id_map(state, issue_map)
        state.fetch("issues").flat_map do |issue|
          old_issue_id = issue.fetch("id")
          new_issue_id = issue_map.fetch(old_issue_id)
          workers = state.fetch("agents").select do |agent|
            agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil) == old_issue_id
          end
          sorted_records(workers, /^#{Regexp.escape(old_issue_id)}-W(\d+)$/).each_with_index.map do |worker, index|
            [worker.fetch("id"), "#{new_issue_id}-W#{index + 1}"]
          end
        end.to_h
      end

      def sorted_records(records, pattern)
        Array(records).each_with_index.sort_by do |(record, index)|
          id = record.fetch("id", "").to_s
          match = id.match(pattern)
          raise ArgumentError, "Cannot recount malformed AgentTree ID #{id.inspect}." unless match

          [match[1].to_i, index]
        end.map(&:first)
      end

      def rewrite_primary_ids!(state, project_map, issue_map, worker_map, question_map)
        state.fetch("projects").each { |project| project["id"] = project_map.fetch(project.fetch("id")) }
        state.fetch("issues").each { |issue| issue["id"] = issue_map.fetch(issue.fetch("id")) }
        state.fetch("agents").each do |agent|
          next unless agent.fetch("type", nil) == "worker"

          agent["id"] = worker_map.fetch(agent.fetch("id"))
        end
        state.fetch("questions").each { |question| question["id"] = question_map.fetch(question.fetch("id")) }
      end

      def rewrite_record_references!(state, id_map)
        state.fetch("issues").each do |issue|
          rewrite_keys!(issue, id_map, %w[project_id parent_issue_id originating_head_id last_agent_id agent_ids])
          rewrite_structured_references!(issue["delivery_pull_request"], id_map)
          rewrite_structured_references!(issue["delivery_pull_requests"], id_map)
        end

        state.fetch("agents").each do |agent|
          rewrite_keys!(agent, id_map, %w[
            project_id issue_id follow_up_of_agent_id replaces_agent_id replaced_by_agent_id follow_up_agent_ids
          ])
          rewrite_structured_references!(agent["harness_metadata"], id_map)
        end

        state.fetch("questions").each do |question|
          rewrite_keys!(question, id_map, %w[head_id project_id issue_id])
        end

        state.fetch("logs").each do |log|
          log["source_id"] = rewrite_id(log["source_id"], id_map)
          rewrite_structured_references!(log["details"], id_map)
        end
      end

      def rewrite_keys!(record, id_map, keys)
        keys.each do |key|
          next unless record.key?(key)

          record[key] = rewrite_reference_value(record[key], id_map)
        end
      end

      def rewrite_structured_references!(value, id_map)
        case value
        when Hash
          value.each do |key, child|
            if reference_key?(key)
              value[key] = rewrite_reference_value(child, id_map)
            else
              rewrite_structured_references!(child, id_map)
            end
          end
        when Array
          value.each { |child| rewrite_structured_references!(child, id_map) }
        end
        value
      end

      def reference_key?(key)
        normalized = key.to_s
                        .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
                        .tr("-", "_")
                        .downcase
        return false if OPAQUE_ID_KEYS.include?(normalized)

        normalized == "id" || normalized.end_with?("_id", "_ids")
      end

      def rewrite_reference_value(value, id_map)
        case value
        when Array
          value.map { |item| rewrite_reference_value(item, id_map) }
        when Hash
          rewrite_structured_references!(value, id_map)
        else
          rewrite_id(value, id_map)
        end
      end

      def rewrite_id(value, id_map)
        value.is_a?(String) ? id_map.fetch(value, value) : value
      end

      def clean_agent_relationships!(state)
        worker_ids = state.fetch("agents").select { |agent| agent.fetch("type", nil) == "worker" }.map { |agent| agent.fetch("id") }
        state.fetch("agents").each do |agent|
          next unless agent.fetch("type", nil) == "worker"

          %w[follow_up_of_agent_id replaces_agent_id replaced_by_agent_id].each do |key|
            next unless agent.key?(key)

            related_id = agent[key]
            agent[key] = nil unless worker_ids.include?(related_id) && related_id != agent.fetch("id")
          end
          if agent.key?("follow_up_agent_ids")
            agent["follow_up_agent_ids"] = Array(agent["follow_up_agent_ids"]).select do |related_id|
              worker_ids.include?(related_id) && related_id != agent.fetch("id")
            end.uniq
          end
        end
      end

      def rebuild_issue_agent_ids!(state)
        workers_by_issue = state.fetch("agents")
                                .select { |agent| agent.fetch("type", nil) == "worker" }
                                .group_by { |agent| agent.fetch("issue_id", nil) }
        state.fetch("issues").each do |issue|
          workers = workers_by_issue.fetch(issue.fetch("id"), [])
          issue["agent_ids"] = workers.sort_by { |worker| worker_number(worker.fetch("id")) }.map { |worker| worker.fetch("id") }
          issue["last_agent_id"] = nil if issue.key?("last_agent_id") && !issue.fetch("agent_ids").include?(issue["last_agent_id"])
        end
      end

      def worker_number(worker_id)
        worker_id.to_s[/\-W(\d+)\z/, 1].to_i
      end

      def reset_counters!(state)
        counters = state.fetch("counters")
        counters["projects"] = state.fetch("projects").length
        counters["questions"] = state.fetch("questions").length
        counters["issues_by_project"] = state.fetch("projects").to_h do |project|
          project_id = project.fetch("id")
          [project_id, state.fetch("issues").count { |issue| issue.fetch("project_id", nil) == project_id }]
        end
        counters["workers_by_issue"] = state.fetch("issues").to_h do |issue|
          issue_id = issue.fetch("id")
          [issue_id, state.fetch("agents").count { |agent| agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil) == issue_id }]
        end
      end

      def validate_integrity!(state)
        project_ids = state.fetch("projects").map { |project| project.fetch("id") }
        issue_ids = state.fetch("issues").map { |issue| issue.fetch("id") }
        worker_ids = state.fetch("agents").select { |agent| agent.fetch("type", nil) == "worker" }.map { |agent| agent.fetch("id") }
        question_ids = state.fetch("questions").map { |question| question.fetch("id") }
        raise ArgumentError, "Recount produced duplicate project IDs." unless project_ids.uniq.length == project_ids.length
        raise ArgumentError, "Recount produced duplicate issue IDs." unless issue_ids.uniq.length == issue_ids.length
        raise ArgumentError, "Recount produced duplicate worker IDs." unless worker_ids.uniq.length == worker_ids.length
        raise ArgumentError, "Recount produced duplicate question IDs." unless question_ids.uniq.length == question_ids.length

        state.fetch("issues").each do |issue|
          raise ArgumentError, "Issue #{issue.fetch("id")} has no project after recount." unless project_ids.include?(issue.fetch("project_id", nil))
          parent_id = issue.fetch("parent_issue_id", nil)
          next unless parent_id

          parent = state.fetch("issues").find { |candidate| candidate.fetch("id", nil) == parent_id }
          unless parent && parent.fetch("project_id", nil) == issue.fetch("project_id", nil)
            raise ArgumentError, "Issue #{issue.fetch("id")} has an invalid parent after recount."
          end
        end
        state.fetch("agents").each do |agent|
          next unless agent.fetch("type", nil) == "worker"

          issue = state.fetch("issues").find { |candidate| candidate.fetch("id", nil) == agent.fetch("issue_id", nil) }
          unless issue && issue.fetch("project_id", nil) == agent.fetch("project_id", nil)
            raise ArgumentError, "Worker #{agent.fetch("id")} has an invalid issue after recount."
          end
        end
        true
      end

      def changed_entries(mapping)
        mapping.reject { |old_id, new_id| old_id == new_id }
      end
    end
  end
end
