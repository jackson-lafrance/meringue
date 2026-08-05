# frozen_string_literal: true

module Meringue
  module TUI
    # AgentTree-selection-scoped log filtering.
    #
    # Exactly one AgentTree node can be selected at a time (project, issue, head,
    # or worker). While a node is selected the logs pane renders only the entries
    # that belong to that node's AgentTree subtree.
    #
    # Membership is derived from data the kernel already writes: each log
    # record's `source_type`/`source_id` plus the routing ids it carries in
    # `details` (`project_id`, `issue_id`, `agent_id`, `head_id`, and the
    # cascading id lists used by kills and prunes). No new log fields are needed.
    #
    # The subtree is assembled exactly like the rendered AgentTree hierarchy:
    # heads are top-level nodes, workers hang off their issue, child issues nest
    # under their parent issue, and every issue belongs to one project. Because
    # heads are top-level rows, head logs (and the user prompt that spawned a
    # head) belong to that head node only, never to a project or issue subtree.
    #
    # This selection is deliberately separate from the text-selection/copy state:
    # it scopes which entries are rendered, not which characters are highlighted.
    module LogScope
      # Key the TUI composes into the rendered state.
      STATE_KEY = "_log_scope"
      # Single-id routing fields that kernel/harness logs already carry.
      ROUTING_KEYS = %w[agent_id issue_id project_id head_id target_id].freeze
      # Routing fields that carry several ids at once, such as cascading kills.
      ROUTING_LIST_KEYS = %w[
        agent_ids
        killed_agent_ids
        removed_agent_ids
        removed_issue_ids
        removed_project_ids
        standalone_agent_ids
        removed_standalone_agent_ids
      ].freeze

      module_function

      # Snapshot handed to the panes. Member ids are resolved once per frame so
      # rendering never re-walks the AgentTree for every log entry.
      def snapshot(state, id)
        record = find_record(state, id)
        return {} unless record

        value = {
          "id" => record.fetch("id").to_s,
          "kind" => kind_for(record),
          "label" => label_for(record),
          "member_ids" => member_ids(state, record)
        }
        target = selected_target_for(state, record)
        value["selected_target"] = target if target
        value
      end

      def scope(state)
        value = (state || {}).fetch(STATE_KEY, nil)
        value.is_a?(Hash) ? value : {}
      end

      def active?(state)
        !id(state).empty?
      end

      def id(state)
        scope(state).fetch("id", "").to_s
      end

      def label(state)
        scope(state).fetch("label", "").to_s
      end

      def kind(state)
        scope(state).fetch("kind", "").to_s
      end

      # Issue/agent selections also become a chat-routing target, and so does a
      # failed head: typing at a selected errored/killed head retries it. Projects
      # and heads that are still routing remain useful log-only filters. The TUI
      # sends only selected_id; the kernel resolves the authoritative issue (or
      # head retry) again before a head is spawned.
      #
      # Renderers ask "what is selected?" and want a Hash they can read fields
      # from, so this is always a Hash and never nil.
      def selected_target(state)
        value = scope(state).fetch("selected_target", nil)
        value.is_a?(Hash) ? value : {}
      end

      # Routing callers ask "is there a target to attach?" and want a
      # present-or-absent value, so an absent, cleared, or unbound selection is
      # nil here instead of an empty Hash every caller has to re-test.
      def chat_target(state)
        target = selected_target(state)
        return target if target.fetch("selected_type", "").to_s == "head"
        return nil if target.fetch("issue_id", "").to_s.empty?

        target
      end

      def chat_target?(state)
        !chat_target(state).nil?
      end

      # True when the id still names a rendered AgentTree node, so a pruned or
      # killed selection can be dropped instead of filtering everything away.
      def selectable?(state, id)
        !find_record(state, id).nil?
      end

      def filter(scope, entries)
        index = member_index(scope)
        return entries if index.empty?

        entries.select { |entry| member?(entry, index) }
      end

      def member?(entry, index)
        return false unless entry.is_a?(Hash)
        return true if index.key?(entry.fetch("source_id", nil).to_s)

        details = entry.fetch("details", nil)
        return false unless details.is_a?(Hash)

        return true if ROUTING_KEYS.any? { |key| index.key?(details.fetch(key, nil).to_s) }

        ROUTING_LIST_KEYS.any? do |key|
          Array(details.fetch(key, nil)).any? { |value| index.key?(value.to_s) }
        end
      end

      def member_index(scope)
        ids = Array(scope.is_a?(Hash) ? scope.fetch("member_ids", []) : [])
        ids.each_with_object({}) do |id, index|
          key = id.to_s
          index[key] = true unless key.empty?
        end
      end

      def find_record(state, id)
        key = id.to_s
        return nil if key.empty?

        agents(state).find { |agent| agent.fetch("id", nil).to_s == key } ||
          issues(state).find { |issue| issue.fetch("id", nil).to_s == key } ||
          projects(state).find { |project| project.fetch("id", nil).to_s == key }
      end

      def kind_for(record)
        type = record.fetch("type", nil).to_s
        return type if %w[head worker].include?(type)
        return "issue" if AgentTreeNavigation.issue_record?(record)

        "project"
      end

      def label_for(record)
        record.fetch("id", "").to_s
      end

      # Selecting an issue targets it directly. Selecting an agent with an owning
      # issue keeps that exact row as the focused log scope while resolving chat
      # to the durable issue. A top-level head has no issue: a failed one is its
      # own retry target, and one that is still routing stays a log-only
      # selection rather than fabricating routing context.
      def selected_target_for(state, record)
        kind = kind_for(record)
        return head_retry_target_for(record) if kind == "head" && State::Models.head_retry_target?(record)

        issue = if kind == "issue"
                  record
                elsif %w[worker head].include?(kind)
                  issues(state).find { |candidate| candidate.fetch("id", nil).to_s == record.fetch("issue_id", nil).to_s }
                end
        return nil unless issue

        target = {
          "selected_id" => record.fetch("id").to_s,
          "selected_type" => kind == "issue" ? "issue" : "agent",
          "issue_id" => issue.fetch("id").to_s,
          "project_id" => issue.fetch("project_id", nil).to_s,
          "issue_title" => issue.fetch("title", nil).to_s
        }
        if kind != "issue"
          metadata = record.fetch("harness_metadata", nil)
          metadata = {} unless metadata.is_a?(Hash)
          target["selected_agent_id"] = record.fetch("id").to_s
          target["selected_agent_type"] = record.fetch("type", nil).to_s
          target["selected_agent_title"] = metadata.fetch("title", nil).to_s
        end
        target.reject { |_key, value| value.to_s.empty? }
      end

      # A failed head is a real chat destination with no issue behind it: the next
      # message retries that head. The TUI still sends only the id; the kernel
      # re-resolves it and owns the resume/respawn decision.
      def head_retry_target_for(record)
        metadata = record.fetch("harness_metadata", nil)
        metadata = {} unless metadata.is_a?(Hash)
        {
          "selected_id" => record.fetch("id").to_s,
          "selected_type" => "head",
          "selected_agent_id" => record.fetch("id").to_s,
          "selected_agent_type" => "head",
          "selected_agent_title" => metadata.fetch("title", nil).to_s,
          "selected_head_status" => record.fetch("status", nil).to_s
        }.reject { |_key, value| value.to_s.empty? }
      end

      # Ids whose logs belong to the selected node, mirroring the AgentTree.
      def member_ids(state, record)
        case kind_for(record)
        when "worker", "head" then [record.fetch("id").to_s]
        when "issue" then issue_member_ids(state, record)
        else project_member_ids(state, record)
        end
      end

      def issue_member_ids(state, issue)
        issue_ids = issue_subtree_ids(issues(state), issue.fetch("id").to_s)
        issue_ids + worker_ids_for_issues(state, issue_ids)
      end

      def project_member_ids(state, project)
        project_id = project.fetch("id").to_s
        issue_ids = issues(state).select { |issue| issue.fetch("project_id", nil).to_s == project_id }
                                 .map { |issue| issue.fetch("id").to_s }
        workers = agents(state).select do |agent|
          next false unless agent.fetch("type", nil).to_s == "worker"

          issue_ids.include?(agent.fetch("issue_id", nil).to_s) ||
            agent.fetch("project_id", nil).to_s == project_id
        end
        [project_id] + issue_ids + workers.map { |agent| agent.fetch("id").to_s }
      end

      def issue_subtree_ids(issues, root_id)
        collected = [root_id]
        frontier = [root_id]
        until frontier.empty?
          parent_id = frontier.shift
          issues.each do |issue|
            next unless issue.fetch("parent_issue_id", nil).to_s == parent_id

            child_id = issue.fetch("id", nil).to_s
            next if child_id.empty? || collected.include?(child_id)

            collected << child_id
            frontier << child_id
          end
        end
        collected
      end

      def worker_ids_for_issues(state, issue_ids)
        agents(state).select do |agent|
          agent.fetch("type", nil).to_s == "worker" && issue_ids.include?(agent.fetch("issue_id", nil).to_s)
        end.map { |agent| agent.fetch("id").to_s }
      end

      # Killed projects/issues are hidden by the AgentTree, so they can never be
      # the selected node either.
      def projects(state)
        AgentTreeNavigation.records(state || {}, "projects")
      end

      def issues(state)
        AgentTreeNavigation.records(state || {}, "issues")
      end

      def agents(state)
        Array((state || {}).fetch("agents", []) || []).select { |agent| agent.is_a?(Hash) }
      end
    end
  end
end
