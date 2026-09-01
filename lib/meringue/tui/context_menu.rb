# frozen_string_literal: true

module Meringue
  module TUI
    # What right-clicking somewhere offers, as data.
    #
    # Right-click used to be one hard-coded action: open an issue's pull request.
    # That does not survive contact with a tree holding four kinds of row, each
    # with a different useful verb, so the gesture now opens a menu and this
    # module decides what is in it.
    #
    # The registry is pure. It reads a state snapshot and returns entries; it
    # never touches the kernel, the filesystem, or the app's instance variables.
    # That keeps "what can I do to this row" testable without a terminal, and
    # keeps the TUI out of the business of mutating orchestration state: an entry
    # either names a local view action the app already implements, or carries a
    # `draft` that pre-fills the composer with the slash command the user could
    # have typed. The kernel stays the only writer either way.
    #
    # An entry that cannot apply right now is kept and disabled rather than
    # dropped, so the menu for a given row kind has a stable shape and the reason
    # is visible instead of the option silently vanishing.
    module ContextMenu
      KINDS = %w[worker head issue project background].freeze

      Entry = Struct.new(:id, :label, :action, :draft, :enabled, :note, keyword_init: true) do
        def enabled?
          enabled != false
        end

        def to_h
          {
            "id" => id.to_s,
            "label" => label.to_s,
            "action" => action&.to_s,
            "draft" => draft,
            "enabled" => enabled?,
            "note" => note
          }.compact
        end
      end

      module_function

      # The row kind at `target_id`, or "background" when the click landed on
      # empty tree space.
      def kind_for(state, target_id)
        return "background" if target_id.to_s.strip.empty?

        record = find_record(state, target_id)
        return "background" unless record

        case record
        when ->(candidate) { candidate.key?("root_path") } then "project"
        when ->(candidate) { candidate.key?("project_id") && !candidate.key?("type") } then "issue"
        else record.fetch("type", nil) == "head" ? "head" : "worker"
        end
      end

      def find_record(state, target_id)
        id = target_id.to_s
        return nil if id.empty?

        %w[projects issues agents].each do |section|
          found = Array((state || {}).fetch(section, [])).find do |record|
            record.is_a?(Hash) && record["id"].to_s == id
          end
          return found if found
        end
        nil
      end

      # Entries for the row, newest-relevant verb first. `github_enabled` gates
      # the pull-request entry because a delivery PR is only meaningful when the
      # GitHub experiment is on.
      def entries(state, target_id, github_enabled: false)
        kind = kind_for(state, target_id)
        record = find_record(state, target_id)
        case kind
        when "worker" then worker_entries(state, record, github_enabled)
        when "head" then head_entries(record, github_enabled)
        when "issue" then issue_entries(state, record, github_enabled)
        when "project" then project_entries(state, record)
        else background_entries(state)
        end
      end

      def worker_entries(state, worker, github_enabled)
        id = worker.fetch("id")
        status = worker.fetch("status", "").to_s
        settled = %w[completed killed errored supervision_lost].include?(status)
        [
          Entry.new(id: "open_workspace", label: "Open workspace", action: "open_workspace"),
          Entry.new(id: "info", label: "Info", action: "info"),
          Entry.new(
            id: worker.fetch("prune_protected", false) ? "unprotect" : "protect",
            label: worker.fetch("prune_protected", false) ? "Allow pruning" : "Protect from pruning",
            draft: "/worker #{worker.fetch("prune_protected", false) ? "unprotect" : "protect"} #{id}"
          ),
          Entry.new(id: "prompt", label: "Prompt…", draft: "/prompt #{id} "),
          if status == "paused"
            Entry.new(id: "resume", label: "Resume", draft: "/worker resume #{id}")
          else
            Entry.new(
              id: "pause", label: "Pause", draft: "/worker pause #{id}",
              enabled: !settled, note: settled ? "already #{status}" : nil
            )
          end,
          Entry.new(
            id: "move", label: "Move to issue…", draft: "/move #{id} ",
            enabled: move_targets?(state, worker), note: move_targets?(state, worker) ? nil : "no other issue to move to"
          ),
          Entry.new(id: "merge", label: "Merge into worker…", draft: "/worker merge #{id} "),
          Entry.new(id: "split", label: "Extract worker…", draft: "/worker split #{id} "),
          Entry.new(
            id: "open_pr", label: "Open pull request", action: "open_pr",
            enabled: github_enabled, note: github_enabled ? nil : "GitHub support is off"
          ),
          Entry.new(
            id: "kill", label: "Kill", draft: "/kill #{id}",
            enabled: !settled, note: settled ? "already #{status}" : nil
          )
        ].compact
      end

      def head_entries(head, github_enabled)
        id = head.fetch("id")
        [
          Entry.new(id: "info", label: "Info", action: "info"),
          Entry.new(
            id: head.fetch("prune_protected", false) ? "unprotect" : "protect",
            label: head.fetch("prune_protected", false) ? "Allow pruning" : "Protect from pruning",
            draft: "/worker #{head.fetch("prune_protected", false) ? "unprotect" : "protect"} #{id}"
          ),
          Entry.new(id: "retry", label: "Retry", draft: "/retry #{id}"),
          Entry.new(
            id: "open_pr", label: "Open pull request", action: "open_pr",
            enabled: github_enabled, note: github_enabled ? nil : "GitHub support is off"
          ),
          Entry.new(id: "kill", label: "Kill", draft: "/kill #{id}")
        ]
      end

      def issue_entries(state, issue, github_enabled)
        id = issue.fetch("id")
        siblings = sibling_projects(state, issue.fetch("project_id", nil))
        [
          Entry.new(id: "info", label: "Info", action: "info"),
          Entry.new(id: "spawn", label: "Spawn worker…", draft: "/worker spawn #{id} "),
          Entry.new(id: "rename", label: "Rename…", draft: "/issue rename #{id} "),
          Entry.new(
            id: "move_project", label: "Move to project…", draft: "/issue move #{id} ",
            enabled: !siblings.empty?,
            note: siblings.empty? ? "no other project on this checkout" : nil
          ),
          Entry.new(id: "merge", label: "Merge into issue…", draft: "/issue merge #{id} "),
          Entry.new(id: "split", label: "Extract workers…", draft: "/issue split #{id} "),
          Entry.new(
            id: "promote", label: "Promote to top level", draft: "/issue move #{id} top",
            enabled: !issue.fetch("parent_issue_id", nil).to_s.strip.empty?,
            note: issue.fetch("parent_issue_id", nil).to_s.strip.empty? ? "already top level" : nil
          ),
          Entry.new(
            id: "open_pr", label: "Open pull request", action: "open_pr",
            enabled: github_enabled, note: github_enabled ? nil : "GitHub support is off"
          ),
          Entry.new(id: "kill", label: "Kill subtree", draft: "/kill #{id}")
        ]
      end

      def project_entries(state, project)
        id = project.fetch("id")
        [
          Entry.new(id: "info", label: "Info", action: "info"),
          Entry.new(id: "create_issue", label: "New issue…", draft: "/issue create #{id} "),
          Entry.new(id: "rename", label: "Rename…", draft: "/project rename #{id} "),
          Entry.new(
            id: "add_sibling", label: "New project here…",
            draft: "/project add #{project.fetch("root_path", "")} ",
            note: "a second board over the same directory"
          ),
          Entry.new(id: "merge", label: "Merge into project…", draft: "/project merge #{id} "),
          Entry.new(id: "split", label: "Extract issues…", draft: "/project split #{id} "),
          Entry.new(id: "kill", label: "Kill subtree", draft: "/kill #{id}")
        ]
      end

      def background_entries(_state)
        [
          Entry.new(id: "add_project", label: "Add project…", draft: "/project add "),
          Entry.new(id: "prs", label: "Open pull requests", draft: "/prs"),
          Entry.new(id: "prune", label: "Prune resolved", draft: "/prune"),
          Entry.new(id: "recount", label: "Recount ids", draft: "/recount")
        ]
      end

      # Other projects registered against the same directory. Only those can
      # receive an issue, because a worker's checkout has to stay valid.
      def sibling_projects(state, project_id)
        projects = Array((state || {}).fetch("projects", []))
        current = projects.find { |project| project.is_a?(Hash) && project["id"].to_s == project_id.to_s }
        return [] unless current

        root = expanded_root(current)
        return [] if root.nil?

        projects.select do |project|
          project.is_a?(Hash) && project["id"].to_s != project_id.to_s && expanded_root(project) == root
        end
      end

      def expanded_root(project)
        value = project.fetch("root_path", nil).to_s
        return nil if value.strip.empty?

        File.expand_path(value)
      end

      def move_targets?(state, worker)
        Array((state || {}).fetch("issues", [])).any? do |issue|
          issue.is_a?(Hash) && issue["id"].to_s != worker.fetch("issue_id", nil).to_s
        end
      end
    end
  end
end
