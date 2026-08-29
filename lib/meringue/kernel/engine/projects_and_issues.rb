# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # The AgentTree's own records: projects, issues, and moving an issue or a worker between them.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def add_project(command_id, command_type, payload)
        root_path = value_at(payload, "path", "Path", "root_path", "RootPath")
        name = value_at(payload, "name", "Name")
        errors = []

        errors << "path is required" if blank?(root_path)
        expanded_path = File.expand_path(root_path.to_s) unless blank?(root_path)
        errors << "path must be an existing directory" if expanded_path && !Dir.exist?(expanded_path)
        return rejected_result(command_id, command_type, "Project was not added.", errors) unless errors.empty?

        capability = @version_control_backend.inspect_project(root_path: expanded_path)
        unless capability.is_a?(Hash) && capability["available"] == true && capability.dig("capabilities", "isolated_workspaces") == true
          diagnostics = Array(capability.is_a?(Hash) ? capability["diagnostics"] : nil).join(", ")
          reason = diagnostics.empty? ? "isolated_workspace_capability_missing" : diagnostics
          return rejected_result(command_id, command_type, "Project was not added: isolated mutable workspaces are unavailable (#{reason}).", ["version_control_backend_unavailable", reason])
        end

        state = normalized_state
        requested_name = project_display_name(name)
        projects_at_path = state.fetch("projects").select do |project|
          File.expand_path(project.fetch("root_path")) == expanded_path
        end
        head_id = present_string(value_at(payload, "_head_id"))
        head = head_id && find_agent(state, head_id)
        head_request = !head.nil? && head.fetch("type", nil) == "head"

        # A directory can hold several logical projects: someone working a
        # migration and a resiliency effort in one repository wants two separate
        # boards over the same files. So for a person, identity is the
        # (path, name) pair, and an unnamed request still means "the project at
        # this path", preserving the historical single-project contract.
        #
        # A head is deliberately excluded from that. Two heads can each observe an
        # unregistered root and propose AddProject with a name they invented
        # before either result lands; if the loser's differing name created a
        # second board, the rest of its batch would bind to the wrong project.
        # Registration by a head therefore stays idempotent per path, and opening
        # a second board is left to the person who wants one.
        existing_project = if head_request || requested_name.nil?
                             projects_at_path.first
                           else
                             projects_at_path.find { |project| same_project_name?(project.fetch("name"), requested_name) }
                           end
        if existing_project
          if head_request
            now = timestamp
            log_ids = append_log(
              state,
              source_type: "kernel",
              source_id: existing_project.fetch("id"),
              level: "info",
              message: "Reused project #{existing_project.fetch("id")} for head #{head_id}: #{existing_project.fetch("name")}",
              details: {
                "root_path" => expanded_path,
                "head_id" => head_id,
                "reused" => true
              }
            )
            touch_state!(state, now)
            store.save(state)

            return accepted_result(
              command_id,
              command_type,
              existing_project.fetch("id"),
              "Project #{existing_project.fetch("id")} is already registered; reused it.",
              existing_project,
              log_ids
            )
          end

          message = if requested_name && same_project_name?(existing_project.fetch("name"), requested_name)
                      "Project #{existing_project.fetch("id")} is already registered at that path under the name #{requested_name.inspect}."
                    else
                      "Project is already registered."
                    end
          return rejected_result(command_id, command_type, message, ["project_already_exists"])
        end

        now = timestamp
        project_id = next_project_id!(state)
        project = {
          "id" => project_id,
          "name" => requested_name || default_project_name(expanded_path),
          "root_path" => expanded_path,
          "version_control_backend" => capability.fetch("backend", @version_control_backend.id),
          "version_control_repository_identity" => capability["repository_identity"],
          "version_control_capabilities" => capability.fetch("capabilities", {}),
          "version_control_diagnostic_at" => capability["diagnostic_at"],
          "status" => "working",
          "created_at" => now,
          "updated_at" => now
        }

        state.fetch("projects") << project
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: project_id,
          level: "info",
          message: "Added project #{project_id}: #{project.fetch("name")}",
          details: {
            "root_path" => expanded_path,
            "version_control_backend" => project.fetch("version_control_backend"),
            "isolated_mutable_workspaces" => true,
            "projects_sharing_root_path" => projects_at_path.length + 1
          }
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, project_id, "Added project #{project_id}.", project, log_ids)
      end

      # ModifyProject is the only command that renames a project (ModifyIssue retitles an issue).
      # A `Rename` wrapper used to sit above this method and sniff whether a bare target id was a
      # project or an issue, but it existed only to back the removed `/rename <id> "<name>"` slash
      # command, so renaming is now always the explicit command for the record kind being changed.
      def modify_project(command_id, command_type, payload)
        project_id = value_at(payload, "project_id", "ProjectID", "projectId", "target_id", "TargetID", "targetId")
        name = value_at(payload, "name", "Name", "title", "Title")
        errors = []

        errors << "project_id is required" if blank?(project_id)
        errors << "name is required" if blank?(name)
        return rejected_result(command_id, command_type, "Project was not renamed.", errors) unless errors.empty?

        state = normalized_state
        project = find_project(state, project_id)
        return rejected_result(command_id, command_type, "Project #{project_id} does not exist.", ["project_not_found"]) unless project

        now = timestamp
        previous_name = project.fetch("name", "")
        project["name"] = project_display_name(name) || name.to_s.strip
        project["updated_at"] = now
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: project.fetch("id"),
          level: "info",
          message: "Renamed project #{project.fetch("id")}: #{previous_name} -> #{project.fetch("name")}",
          details: {
            "changed_fields" => ["name"],
            "previous_name" => previous_name,
            "name" => project.fetch("name")
          }
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, project.fetch("id"), "Renamed project #{project.fetch("id")}.", project, log_ids)
      end

      def create_issue(command_id, command_type, payload)
        project_id = value_at(payload, "project_id", "ProjectID", "projectId")
        title = value_at(payload, "title", "Title")
        description = value_at(payload, "description", "Description") || ""
        parent_issue_id = value_at(payload, "parent_issue_id", "ParentIssueID", "parentIssueId")
        originating_head_id = value_at(payload, "originating_head_id", "originatingHeadId", "_head_id")
        status = value_at(payload, "status", "Status") || "queued"
        errors = []

        errors << "project_id is required" if blank?(project_id)
        errors << "title is required" if blank?(title)
        errors << "status must be one of #{State::Models::LIFECYCLE_STATUSES.join(", ")}" unless State::Models::LIFECYCLE_STATUSES.include?(status.to_s)
        return rejected_result(command_id, command_type, "Issue was not created.", errors) unless errors.empty?

        state = normalized_state
        project = find_project(state, project_id)
        return rejected_result(command_id, command_type, "Project #{project_id} does not exist.", ["project_not_found"]) unless project

        if present_string(parent_issue_id)
          parent = find_issue(state, parent_issue_id)
          unless parent && parent.fetch("project_id") == project.fetch("id")
            return rejected_result(command_id, command_type, "Parent issue #{parent_issue_id} does not exist in #{project.fetch("id")}.", ["parent_issue_not_found"])
          end
        end

        now = timestamp
        issue_id = next_issue_id!(state, project.fetch("id"))
        issue = {
          "id" => issue_id,
          "project_id" => project.fetch("id"),
          "parent_issue_id" => present_string(parent_issue_id),
          "originating_head_id" => present_string(originating_head_id),
          "title" => title.to_s.strip,
          "description" => description.to_s,
          "status" => status.to_s,
          "agent_ids" => [],
          "created_at" => now,
          "updated_at" => now
        }

        state.fetch("issues") << issue
        project["updated_at"] = now
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: issue_id,
          level: "info",
          message: "Created issue #{issue_id}: #{issue.fetch("title")}",
          details: { "project_id" => project.fetch("id"), "parent_issue_id" => issue.fetch("parent_issue_id") }
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, issue_id, "Created issue #{issue_id}.", issue, log_ids)
      end

      def modify_issue(command_id, command_type, payload)
        issue_id = value_at(payload, "issue_id", "IssueID", "issueId")
        title = value_at(payload, "title", "Title")
        description = value_at(payload, "description", "Description")
        parent_issue_id = value_at(payload, "parent_issue_id", "ParentIssueID", "parentIssueId")
        status = value_at(payload, "status", "Status")
        errors = []

        errors << "issue_id is required" if blank?(issue_id)
        errors << "status must be one of #{State::Models::LIFECYCLE_STATUSES.join(", ")}" if present_string(status) && !State::Models::LIFECYCLE_STATUSES.include?(status.to_s)
        return modify_issue_rejection(command_id, command_type, payload, "Issue was not modified.", errors) unless errors.empty?

        state = normalized_state
        issue = find_issue(state, issue_id)
        return modify_issue_rejection(command_id, command_type, payload, missing_modify_issue_message(state, issue_id), ["issue_not_found"]) unless issue

        project = find_project(state, issue.fetch("project_id"))
        return modify_issue_rejection(command_id, command_type, payload, "Project #{issue.fetch("project_id")} does not exist.", ["project_not_found"]) unless project

        if payload_has?(payload, "parent_issue_id", "ParentIssueID", "parentIssueId") && present_string(parent_issue_id)
          parent = find_issue(state, parent_issue_id)
          return modify_issue_rejection(command_id, command_type, payload, "Parent issue #{parent_issue_id} does not exist in #{project.fetch("id")}.", ["parent_issue_not_found"]) unless parent && parent.fetch("project_id") == project.fetch("id")
          return modify_issue_rejection(command_id, command_type, payload, "Issue cannot be its own parent.", ["invalid_parent_issue"]) if parent.fetch("id") == issue.fetch("id")
        end

        now = timestamp
        changed_fields = []
        if payload_has?(payload, "title", "Title")
          issue["title"] = title.to_s.strip
          changed_fields << "title"
        end
        if payload_has?(payload, "description", "Description")
          issue["description"] = description.to_s
          changed_fields << "description"
        end
        if payload_has?(payload, "parent_issue_id", "ParentIssueID", "parentIssueId")
          issue["parent_issue_id"] = present_string(parent_issue_id)
          changed_fields << "parent_issue_id"
        end
        if present_string(status)
          issue["status"] = status.to_s
          changed_fields << "status"
        end

        issue["updated_at"] = now
        project["updated_at"] = now
        update_project_status_from_issues!(state, project, now)
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: issue.fetch("id"),
          level: "info",
          message: "Modified issue #{issue.fetch("id")}: #{changed_fields.empty? ? "no fields changed" : changed_fields.join(", ")}",
          details: {
            "project_id" => project.fetch("id"),
            "changed_fields" => changed_fields
          }
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, issue.fetch("id"), "Modified issue #{issue.fetch("id")}.", issue, log_ids)
      end

      # A ModifyIssue that does not land is an edit the user asked for and did not get, so every
      # rejection names the update it dropped rather than leaving "1 rejected" as the only trace.
      def modify_issue_rejection(command_id, command_type, payload, message, errors)
        rejected_result(
          command_id,
          command_type,
          with_dropped_intent(message, "type" => "ModifyIssue", "payload" => payload),
          errors
        )
      end

      def missing_modify_issue_message(state, issue_id)
        removal = removed_issue_record(state, issue_id)
        return "Issue #{issue_id} does not exist." unless removal

        "Issue #{issue_id} no longer exists: it was removed #{issue_removal_phrase(removal)}."
      end

      # MoveWorker reparents an existing worker to another issue in the same project without
      # disturbing its harness session, workspace, worktree, or branch. The worker id is renumbered
      # to the composite key of its new issue (P1-I1-W1 -> P1-I7-W2), and every reference that
      # named it is re-pointed in the same pass. Cross-project moves are refused: preserving a
      # session in its original repository while assigning it to another project would route later
      # prompts into the wrong workspace. A worker with background provisioning in flight is also
      # refused because that executor owns its current id until the session has started.
      def move_worker(command_id, command_type, payload)
        agent_id = value_at(payload, "agent_id", "AgentID", "agentId")
        target_issue_id = value_at(payload, "target_issue_id", "TargetIssueID", "targetIssueId", "issue_id", "IssueID", "issueId")
        errors = []

        errors << "agent_id is required" if blank?(agent_id)
        errors << "target_issue_id is required" if blank?(target_issue_id)
        return move_worker_rejection(command_id, command_type, payload, "Worker was not moved.", errors) unless errors.empty?

        state = normalized_state
        agent = find_agent(state, agent_id)
        if agent.nil?
          removal = removed_agent_record(state, agent_id)
          message = removal ? "Agent #{agent_id} no longer exists: it was removed #{issue_removal_phrase(removal)}." : "Agent #{agent_id} does not exist."
          return move_worker_rejection(command_id, command_type, payload, message, ["agent_not_found"])
        end
        if agent.fetch("type", nil) == "head"
          return move_worker_rejection(
            command_id,
            command_type,
            payload,
            "Agent #{agent.fetch("id")} is a head, not a worker. Heads handle one message and are killed afterwards, so they cannot be reparented.",
            ["agent_is_not_worker"]
          )
        end

        target_issue = find_issue(state, target_issue_id)
        if target_issue.nil?
          removal = removed_issue_record(state, target_issue_id)
          message = removal ? "Issue #{target_issue_id} no longer exists: it was removed #{issue_removal_phrase(removal)}." : "Issue #{target_issue_id} does not exist."
          return move_worker_rejection(command_id, command_type, payload, message, ["target_issue_not_found"])
        end
        target_project = find_project(state, target_issue.fetch("project_id"))
        if target_project.nil?
          return move_worker_rejection(
            command_id,
            command_type,
            payload,
            "Target issue #{target_issue.fetch("id")} belongs to project #{target_issue.fetch("project_id")}, which no longer exists.",
            ["target_project_not_found"]
          )
        end

        old_issue_id = present_string(agent.fetch("issue_id", nil))
        old_project_id = present_string(agent.fetch("project_id", nil))
        unless old_project_id && find_project(state, old_project_id)
          return move_worker_rejection(
            command_id,
            command_type,
            payload,
            "Worker #{agent.fetch("id")} does not belong to an existing source project, so its workspace ownership cannot be moved safely.",
            ["source_project_not_found"]
          )
        end
        # Moving between projects is safe exactly when it does not change
        # repositories. Two logical projects over one directory share a checkout,
        # so the worker keeps its workspace, branch, and live harness session and
        # only its board changes. Different roots would strand the worker's
        # worktree under a project that does not own it.
        cross_project = !Ids.same?(old_project_id, target_project.fetch("id"))
        if cross_project && !projects_share_root_path?(state, old_project_id, target_project)
          return move_worker_rejection(
            command_id,
            command_type,
            payload,
            "Worker #{agent.fetch("id")} cannot move to a project in a different repository. Spawn a worker on #{target_issue.fetch("id")} so it receives that project's workspace.",
            ["cross_project_move_unsupported"]
          )
        end
        if old_issue_id && Ids.same?(old_issue_id, target_issue.fetch("id"))
          return move_worker_rejection(
            command_id,
            command_type,
            payload,
            "Worker #{agent.fetch("id")} is already on issue #{target_issue.fetch("id")}; nothing to move.",
            ["already_on_target_issue"]
          )
        end
        provisioning_state = (agent.fetch("harness_metadata", {}) || {}).fetch("provisioning_state", nil).to_s
        if %w[provisioning_queued allocating_workspace starting_harness retry_pending].include?(provisioning_state) &&
           !agent_has_session_reference?(agent)
          return move_worker_rejection(
            command_id,
            command_type,
            payload,
            "Worker #{agent.fetch("id")} is still provisioning. Move it after its harness session has started.",
            ["worker_provisioning_in_progress"]
          )
        end

        old_agent_id = agent.fetch("id")
        new_issue_id = target_issue.fetch("id")
        new_project_id = target_issue.fetch("project_id")
        # Mint the new composite worker id before mutating issue_id so the new issue's high-water
        # mark counter does not count the moved worker itself.
        new_agent_id = next_worker_id!(state, new_issue_id)

        now = timestamp
        # Re-point every structured reference and prose id that names the old worker id. This is
        # the same whole-document walk `/recount` uses, narrowed to a single id substitution so
        # nothing else is cleared: a slot is rewritten only when its value is exactly the old
        # worker id, and every other reference (issue, project, parent, unrelated agents) is left
        # byte-for-byte intact. Opaque correlation ids and verbatim harness evidence (session id,
        # pid, cwd, branch) are skipped by the walker, which is what keeps the session alive.
        repoint_agent_references!(state, old_agent_id, new_agent_id)

        moved = find_agent(state, new_agent_id)
        moved["issue_id"] = new_issue_id
        moved["project_id"] = new_project_id
        moved["updated_at"] = now
        # Preserve the lineage the worker brought with it (follow_up_of_agent_id, replaces_agent_id,
        # replaced_by_agent_id, after_agent_id). They still resolve to the same predecessor or
        # successor records, and the re-point pass already updated successors that point back at
        # this worker. Handover context for dependents is refreshed below.

        # A dependent queued behind the moved worker records the predecessor's issue in its
        # deferred_spawn block for display and recount validation. The flat after_agent_id and
        # deferred_spawn.after_agent_id were re-pointed to the new worker id by the walk; update
        # the recorded predecessor issue so the chain still agrees after the move.
        refresh_deferred_predecessor_issue!(state, new_agent_id, new_issue_id)

        # Rebuild issue agent_ids from the workers' issue_id field so the old issue drops the
        # moved worker and the new issue gains it, regardless of what the re-point pass renamed.
        State::Recounter.rebuild_issue_agent_ids!(state)
        # The old issue's worker counter is a high-water mark; clamp it to the remaining workers.
        decrement_worker_counter!(state, old_issue_id) if old_issue_id

        # Moving a live worker changes both issue roll-ups. In particular, an emptied source issue
        # must not remain stuck in `working`, and a previously settled destination becomes active.
        refresh_issue_status_after_worker_move!(state, find_issue(state, old_issue_id), now)
        refresh_issue_status_after_worker_move!(state, target_issue, now)
        update_project_status_from_issues!(state, target_project, now)
        if cross_project
          source_project = find_project(state, old_project_id)
          update_project_status_from_issues!(state, source_project, now) if source_project
        end

        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: new_agent_id,
          level: "info",
          message: "Moved worker #{old_agent_id} to #{new_agent_id} on issue #{new_issue_id} without restarting its harness session.",
          details: {
            "old_agent_id" => old_agent_id,
            "new_agent_id" => new_agent_id,
            "old_issue_id" => old_issue_id,
            "new_issue_id" => new_issue_id,
            "old_project_id" => old_project_id,
            "new_project_id" => new_project_id,
            "cross_project" => cross_project,
            "harness_session_preserved" => true
          }.compact
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, new_agent_id, "Moved worker #{old_agent_id} to #{new_agent_id} on issue #{new_issue_id}.", moved, log_ids)
      end

      # Two logical projects are the same checkout when their roots resolve to
      # one directory. Comparing expanded paths keeps `.`/symlink spellings and a
      # trailing slash from reading as different repositories.
      def projects_share_root_path?(state, source_project_id, target_project)
        source_project = find_project(state, source_project_id)
        return false unless source_project && target_project

        source_root = present_string(source_project.fetch("root_path", nil))
        target_root = present_string(target_project.fetch("root_path", nil))
        return false unless source_root && target_root

        File.expand_path(source_root) == File.expand_path(target_root)
      end

      def refresh_issue_status_after_worker_move!(state, issue, now)
        return unless issue

        workers = state.fetch("agents").select do |candidate|
          candidate.fetch("type", nil) == "worker" && candidate.fetch("issue_id", nil) == issue.fetch("id") &&
            candidate.fetch("status", nil) != "killed"
        end
        if workers.empty?
          issue["status"] = issue_has_active_goal?(state, issue.fetch("id")) ? "working" : "idle"
          issue["updated_at"] = now
        else
          update_issue_status_from_workers!(state, issue, now)
        end
      end

      # MoveIssue is the issue-level counterpart to MoveWorker: it reparents an
      # issue under another issue, promotes it to the top level, or moves it to a
      # different logical project over the same checkout. An issue never moves
      # alone — its descendants and every worker beneath them travel with it, so
      # a board stays internally consistent.
      #
      # Crossing projects renumbers the whole subtree, because an issue id is
      # composite (`P1-I3`) and a worker id is composite on top of that
      # (`P1-I3-W2`). Reparenting inside one project changes only parentage, so
      # ids and sessions are untouched.
      def move_issue(command_id, command_type, payload)
        issue_id = value_at(payload, "issue_id", "IssueID", "issueId", "target_id", "TargetID", "targetId")
        target_project_id = value_at(payload, "target_project_id", "TargetProjectID", "targetProjectId", "project_id", "ProjectID", "projectId")
        parent_given = payload_key?(payload, "parent_issue_id", "ParentIssueID", "parentIssueId", "parent", "Parent")
        parent_issue_id = value_at(payload, "parent_issue_id", "ParentIssueID", "parentIssueId", "parent", "Parent")

        return move_issue_rejection(command_id, command_type, payload, "Issue was not moved.", ["issue_id is required"]) if blank?(issue_id)
        if blank?(target_project_id) && !parent_given
          return move_issue_rejection(
            command_id, command_type, payload,
            "Issue was not moved.",
            ["target_project_id or parent_issue_id is required"]
          )
        end

        state = normalized_state
        issue = find_issue(state, issue_id)
        if issue.nil?
          removal = removed_issue_record(state, issue_id)
          message = removal ? "Issue #{issue_id} no longer exists: it was removed #{issue_removal_phrase(removal)}." : "Issue #{issue_id} does not exist."
          return move_issue_rejection(command_id, command_type, payload, message, ["issue_not_found"])
        end

        source_project_id = issue.fetch("project_id")
        target_project = if blank?(target_project_id)
                           find_project(state, source_project_id)
                         else
                           find_project(state, target_project_id)
                         end
        if target_project.nil?
          return move_issue_rejection(command_id, command_type, payload, "Project #{target_project_id} does not exist.", ["target_project_not_found"])
        end

        cross_project = !Ids.same?(source_project_id, target_project.fetch("id"))
        if cross_project && !projects_share_root_path?(state, source_project_id, target_project)
          return move_issue_rejection(
            command_id, command_type, payload,
            "Issue #{issue.fetch("id")} cannot move to a project in a different repository, because its workers' checkouts belong to #{source_project_id}.",
            ["cross_repository_move_unsupported"]
          )
        end

        subtree = issue_subtree_ids(state, issue.fetch("id"))
        new_parent_id = nil
        if parent_given && !blank?(parent_issue_id) && !%w[none root top null].include?(parent_issue_id.to_s.strip.downcase)
          parent = find_issue(state, parent_issue_id)
          if parent.nil?
            return move_issue_rejection(command_id, command_type, payload, "Parent issue #{parent_issue_id} does not exist.", ["parent_issue_not_found"])
          end
          if subtree.any? { |candidate| Ids.same?(candidate, parent.fetch("id")) }
            return move_issue_rejection(
              command_id, command_type, payload,
              "Issue #{issue.fetch("id")} cannot become a child of #{parent.fetch("id")}, which sits inside it.",
              ["parent_is_descendant"]
            )
          end
          unless Ids.same?(parent.fetch("project_id"), target_project.fetch("id"))
            return move_issue_rejection(
              command_id, command_type, payload,
              "Parent issue #{parent.fetch("id")} belongs to #{parent.fetch("project_id")}, not #{target_project.fetch("id")}.",
              ["parent_in_other_project"]
            )
          end
          new_parent_id = parent.fetch("id")
        end

        current_parent = present_string(issue.fetch("parent_issue_id", nil))
        if !cross_project && parent_given && Ids.same?(current_parent.to_s, new_parent_id.to_s)
          return move_issue_rejection(
            command_id, command_type, payload,
            "Issue #{issue.fetch("id")} already sits there; nothing to move.",
            ["already_in_target_location"]
          )
        end
        if !cross_project && !parent_given
          return move_issue_rejection(
            command_id, command_type, payload,
            "Issue #{issue.fetch("id")} is already in #{target_project.fetch("id")}; nothing to move.",
            ["already_in_target_location"]
          )
        end

        now = timestamp
        mapping = cross_project ? issue_move_id_mapping(state, subtree, target_project.fetch("id")) : {}
        repoint_moved_ids!(state, mapping) unless mapping.empty?

        moved_root_id = mapping.fetch(issue.fetch("id"), issue.fetch("id"))
        moved_ids = subtree.map { |old| mapping.fetch(old, old) }
        moved_ids.each do |moved_id|
          record = find_issue(state, moved_id)
          next unless record

          record["project_id"] = target_project.fetch("id")
          record["updated_at"] = now
          state.fetch("agents").each do |agent|
            next unless agent.is_a?(Hash) && Ids.same?(agent.fetch("issue_id", nil).to_s, moved_id)

            agent["project_id"] = target_project.fetch("id")
            agent["updated_at"] = now
          end
        end

        moved_root = find_issue(state, moved_root_id)
        # The root's own parent does not travel with it: either the caller named a
        # new one, or it becomes top-level in the project it landed in.
        moved_root["parent_issue_id"] = new_parent_id if parent_given || cross_project
        moved_root["updated_at"] = now

        State::Recounter.rebuild_issue_agent_ids!(state)
        source_project = find_project(state, source_project_id)
        update_project_status_from_issues!(state, target_project, now)
        update_project_status_from_issues!(state, source_project, now) if source_project && cross_project

        description = if cross_project
                        "Moved issue #{issue.fetch("id")} to #{moved_root_id} in project #{target_project.fetch("id")}."
                      elsif new_parent_id
                        "Moved issue #{moved_root_id} under #{new_parent_id}."
                      else
                        "Moved issue #{moved_root_id} to the top level of #{target_project.fetch("id")}."
                      end

        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: moved_root_id,
          level: "info",
          message: description,
          details: {
            "old_issue_id" => issue.fetch("id"),
            "new_issue_id" => moved_root_id,
            "old_project_id" => source_project_id,
            "new_project_id" => target_project.fetch("id"),
            "parent_issue_id" => new_parent_id,
            "cross_project" => cross_project,
            "moved_issue_ids" => moved_ids,
            "renamed_ids" => mapping
          }.compact
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, moved_root_id, description, moved_root, log_ids)
      end

      # The issue and every issue beneath it, parents before children, so callers
      # can mint ids in an order where a parent is always renamed first.
      def issue_subtree_ids(state, root_id)
        ordered = []
        frontier = [root_id]
        until frontier.empty?
          current = frontier.shift
          next if ordered.any? { |seen| Ids.same?(seen, current) }

          ordered << current
          state.fetch("issues").each do |candidate|
            next unless candidate.is_a?(Hash)
            next unless Ids.same?(candidate.fetch("parent_issue_id", nil).to_s, current.to_s)

            frontier << candidate.fetch("id")
          end
        end
        ordered
      end

      # Old id => new id for a subtree changing projects, covering the issues and
      # the workers beneath them. Worker numbering restarts under the new issue id
      # rather than being carried over, matching how MoveWorker renumbers.
      def issue_move_id_mapping(state, subtree, target_project_id)
        mapping = {}
        subtree.each do |old_issue_id|
          new_issue_id = next_issue_id!(state, target_project_id)
          mapping[old_issue_id] = new_issue_id
          workers = state.fetch("agents").select do |agent|
            agent.is_a?(Hash) && Ids.same?(agent.fetch("issue_id", nil).to_s, old_issue_id)
          end
          workers.each_with_index do |worker, index|
            mapping[worker.fetch("id")] = "#{new_issue_id}-W#{index + 1}"
          end
          state.fetch("counters").fetch("workers_by_issue")[new_issue_id] = workers.length
          state.fetch("counters").fetch("workers_by_issue").delete(old_issue_id)
        end
        mapping
      end

      # One walk applies the whole mapping, so a composite id and the ids nested
      # under it are rewritten in the same pass and no intermediate state exists
      # where half a subtree has been renamed.
      def repoint_moved_ids!(state, mapping)
        return if mapping.empty?

        State::Recounter.walk_references!(state) do |value, _path, reference, _mode|
          if reference
            mapping.fetch(value, value)
          else
            repoint_embedded_moved_ids(value, mapping)
          end
        end
      end

      def repoint_embedded_moved_ids(text, mapping)
        return text unless text.is_a?(String)
        return text unless mapping.keys.any? { |old| text.include?(old) }
        return text unless text.match?(State::Recounter::EMBEDDED_ID_PATTERN)

        text.gsub(State::Recounter::EMBEDDED_ID_PATTERN) { |token| mapping.fetch(token, token) }
      end

      def move_issue_rejection(command_id, command_type, payload, message, errors)
        rejected_result(
          command_id,
          command_type,
          with_dropped_intent(message, "type" => "MoveIssue", "payload" => payload),
          errors
        )
      end

      def move_worker_rejection(command_id, command_type, payload, message, errors)
        rejected_result(
          command_id,
          command_type,
          with_dropped_intent(message, "type" => "MoveWorker", "payload" => payload),
          errors
        )
      end

      # Whole-document re-point of one agent id to another, leaving every other reference intact.
      # A slot is rewritten only when its value is exactly the old worker id; everything else that
      # the `/recount` walk would clear (because it covers the whole id space) is preserved here,
      # because a reparent moves exactly one record. Opaque correlation ids and verbatim harness
      # evidence are skipped by the shared walker, which is what keeps the harness session alive.
      def repoint_agent_references!(state, old_agent_id, new_agent_id)
        return if blank?(old_agent_id) || blank?(new_agent_id) || old_agent_id == new_agent_id

        State::Recounter.walk_references!(state) do |value, _path, reference, _mode|
          if reference
            value == old_agent_id ? new_agent_id : value
          else
            repoint_embedded_agent_id(value, old_agent_id, new_agent_id)
          end
        end
      end

      def repoint_embedded_agent_id(text, old_agent_id, new_agent_id)
        return text unless text.is_a?(String) && text.include?(old_agent_id)
        return text unless text.match?(State::Recounter::EMBEDDED_ID_PATTERN)

        text.gsub(State::Recounter::EMBEDDED_ID_PATTERN) do |token|
          token == old_agent_id ? new_agent_id : token
        end
      end

      # Dependents queued behind the moved worker carry the predecessor's issue id in their
      # deferred_spawn block. The re-point walk updated their after_agent_id to the new worker id
      # but left the recorded predecessor issue alone (it is an issue id, not the agent id), so
      # refresh it to the moved worker's new issue so the chain stays coherent for `/recount` and
      # for the handover prompt the dependent eventually receives.
      def refresh_deferred_predecessor_issue!(state, predecessor_agent_id, new_issue_id)
        state.fetch("agents").each do |candidate|
          next unless candidate.is_a?(Hash) && candidate.fetch("type", nil) == "worker"

          flat_after = present_string(candidate.fetch("after_agent_id", nil))
          deferred = deferred_spawn_metadata(candidate)
          deferred_after = present_string(deferred.fetch("after_agent_id", nil))
          next unless Ids.same?(flat_after || deferred_after, predecessor_agent_id)

          next unless deferred.is_a?(Hash) && !deferred.empty?
          metadata = candidate.fetch("harness_metadata", {}) || {}
          candidate["harness_metadata"] = metadata.merge(
            "deferred_spawn" => deferred.merge("after_agent_issue_id" => new_issue_id)
          )
        end
      end
    end
  end
end
