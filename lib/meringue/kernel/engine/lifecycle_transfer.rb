# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      private

      # Merge and split are state-only transfers. The whole state mutation happens under the
      # engine transaction, while session/workspace fields remain untouched. A live session cannot
      # move between repositories; project merges therefore compare repository identity, not path.
      def lifecycle_transfer(command_id, command_type, payload)
        source_id = value_at(payload, "source_id", "source", "from", "SourceID", "SourceId")
        destination_id = value_at(payload, "destination_id", "destination", "to", "DestinationID", "DestinationId")
        return rejected_result(command_id, command_type, "Source and destination are required.", ["source_id is required", "destination_id is required"]) if blank?(source_id) || blank?(destination_id)
        return rejected_result(command_id, command_type, "Source and destination must differ.", ["source_equals_destination"]) if Ids.same?(source_id, destination_id)

        state = normalized_state
        source, destination = lifecycle_records(state, command_type, source_id, destination_id)
        return rejected_result(command_id, command_type, "Source #{source_id} does not exist.", ["source_not_found"]) unless source
        return rejected_result(command_id, command_type, "Destination #{destination_id} does not exist.", ["destination_not_found"]) unless destination

        case command_type
        when "MergeProject" then merge_project_records!(state, source, destination)
        when "MergeIssue" then merge_issue_records!(state, source, destination)
        when "MergeWorker" then merge_worker_records!(state, source, destination)
        when "SplitProject" then split_project_records!(state, source, destination, payload)
        when "SplitIssue" then split_issue_records!(state, source, destination, payload)
        when "SplitWorker" then split_worker_records!(state, source, destination, payload)
        end

        now = timestamp
        State::Recounter.rebuild_issue_agent_ids!(state)
        State::Recounter.reset_counters!(state)
        refresh_all_rollups!(state, now)
        log_ids = append_log(state, source_type: "kernel", source_id: destination.fetch("id"), level: "info",
                             message: "#{command_type} transferred #{source_id} to #{destination_id}.",
                             details: { "source_id" => source_id, "destination_id" => destination_id })
        touch_state!(state, now)
        store.save(state)
        accepted_result(command_id, command_type, destination.fetch("id"), "#{command_type} transferred #{source_id} to #{destination_id}.", destination, log_ids)
      rescue LifecycleTransferError => e
        rejected_result(command_id, command_type, e.message, [e.code])
      end

      class LifecycleTransferError < StandardError
        attr_reader :code
        def initialize(message, code)
          @code = code
          super(message)
        end
      end

      def lifecycle_records(state, command_type, source_id, destination_id)
        kind = command_type.delete_prefix("Merge").delete_prefix("Split")
        case kind
        when "Project" then [find_project(state, source_id), find_project(state, destination_id)]
        when "Issue" then [find_issue(state, source_id), find_issue(state, destination_id)]
        when "Worker" then [find_agent(state, source_id), find_agent(state, destination_id)]
        else [nil, nil]
        end
      end

      def merge_project_records!(state, source, destination)
        source_root = source["version_control_repository_identity"]
        destination_root = destination["version_control_repository_identity"]
        unless source_root && destination_root && source_root == destination_root
          raise LifecycleTransferError.new("Projects #{source["id"]} and #{destination["id"]} do not share a repository identity.", "different_repositories")
        end
        issue_ids = state["issues"].select { |i| i["project_id"] == source["id"] }.map { |i| i["id"] }
        issue_ids.each { |issue_id| move_issue_records!(state, issue_id, destination["id"]) }
        repoint_moved_ids!(state, { source["id"] => destination["id"] })
        state["projects"].delete(source)
      end

      def merge_issue_records!(state, source, destination)
        source_project = find_project(state, source.fetch("project_id"))
        destination_project = find_project(state, destination.fetch("project_id"))
        unless source_project && destination_project && projects_share_root_path?(state, source_project["id"], destination_project)
          raise LifecycleTransferError.new("Issues #{source["id"]} and #{destination["id"]} do not share a repository identity.", "different_repositories")
        end
        workers = state["agents"].select { |a| a["type"] == "worker" && a["issue_id"] == source["id"] }
        workers.each { |worker| move_worker_records!(state, worker, destination) }
        children = state["issues"].select { |i| Ids.same?(i["parent_issue_id"], source["id"]) }
        children.each { |child| child["parent_issue_id"] = destination["id"] }
        repoint_moved_ids!(state, source["id"] => destination["id"])
        state["issues"].delete(source)
      end

      def merge_worker_records!(state, source, destination)
        live = ->(a) { %w[queued working paused supervision_lost].include?(a["status"].to_s) || agent_has_session_reference?(a) }
        if live.call(source) && live.call(destination)
          raise LifecycleTransferError.new("Workers #{source["id"]} and #{destination["id"]} both have live sessions and cannot combine.", "live_sessions_cannot_combine")
        end
        repoint_agent_references!(state, source["id"], destination["id"])
        state["agents"].delete(source)
      end

      def split_project_records!(state, source, destination, payload)
        source_identity = present_string(source.fetch("version_control_repository_identity", nil))
        destination_identity = present_string(destination.fetch("version_control_repository_identity", nil))
        unless source_identity && destination_identity && source_identity == destination_identity
          raise LifecycleTransferError.new("Projects #{source["id"]} and #{destination["id"]} do not share a repository identity.", "different_repositories")
        end
        selected = Array(value_at(payload, "issue_ids", "issues")).map(&:to_s)
        raise LifecycleTransferError.new("SplitProject needs at least one issue_id.", "issue_ids_required") if selected.empty?
        selected.each { |id| move_issue_records!(state, id, destination["id"]) }
      end

      def split_issue_records!(state, source, destination, payload)
        source_project = find_project(state, source.fetch("project_id"))
        destination_project = find_project(state, destination.fetch("project_id"))
        unless source_project && destination_project && projects_share_root_path?(state, source_project["id"], destination_project)
          raise LifecycleTransferError.new("Issues #{source["id"]} and #{destination["id"]} do not share a repository identity.", "different_repositories")
        end
        selected = Array(value_at(payload, "worker_ids", "workers")).map(&:to_s)
        selected = state["agents"].select { |a| a["type"] == "worker" && a["issue_id"] == source["id"] }.map { |a| a["id"] } if selected.empty?
        selected.each do |id|
          worker = find_agent(state, id)
          move_worker_records!(state, worker, destination) if worker
        end
      end

      def split_worker_records!(state, source, destination, _payload)
        # Extracting a worker is the inverse of merging worker records: move its ownership while
        # retaining its session, checkout, branch, delivery metadata, and queued references.
        move_worker_records!(state, source, destination)
      end

      def move_issue_records!(state, issue_id, project_id)
        issue = find_issue(state, issue_id)
        return unless issue
        old_project = issue["project_id"]
        target = find_project(state, project_id)
        return unless target
        return if old_project == project_id
        subtree = issue_subtree_ids(state, issue["id"])
        mapping = issue_move_id_mapping(state, subtree, project_id)
        repoint_moved_ids!(state, mapping)
        subtree.each do |old|
          moved = find_issue(state, mapping.fetch(old, old))
          moved["project_id"] = project_id if moved
          state["agents"].each do |agent|
            agent["project_id"] = project_id if agent["issue_id"] == moved&.fetch("id", nil)
          end
        end
      end

      def move_worker_records!(state, worker, destination)
        return unless worker
        old = worker["id"]
        new_id = next_worker_id!(state, destination["id"])
        repoint_agent_references!(state, old, new_id)
        moved = find_agent(state, new_id)
        moved["issue_id"] = destination["id"]
        moved["project_id"] = destination["project_id"]
      end

      def refresh_all_rollups!(state, now)
        state["issues"].each { |issue| refresh_issue_status_after_worker_move!(state, issue, now) }
        state["projects"].each { |project| update_project_status_from_issues!(state, project, now) }
      end
    end
  end
end
