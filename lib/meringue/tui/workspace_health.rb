# frozen_string_literal: true

module Meringue
  module TUI
    # Converts missing runtime dependencies into non-destructive workspace notices. Callers can
    # render these in place of a terminal/editor instead of raising or deleting persisted state.
    module WorkspaceHealth
      module_function

      def notices(agent)
        return [notice("error", "Worker record is unavailable.", "Return to the AgentTree and select another worker.")] unless agent.is_a?(Hash)

        messages = []
        workspace_path = agent["workspace_path"].to_s
        if workspace_path.empty?
          messages << notice("warning", "Worker has no tracked workspace path.", "The session can still be inspected if its harness history is available.")
        elsif !Dir.exist?(workspace_path)
          messages << notice("warning", "Worker worktree is unavailable: #{workspace_path}", "Meringue kept the worker and delivery metadata; restore the worktree or open the PR instead.")
        end

        if live_status?(agent) && process_missing?(agent["pid"])
          messages << notice("warning", "Worker harness process is not running.", recovery_detail(agent))
        end

        session_file = agent["harness_session_file"].to_s
        if !session_file.empty? && !File.file?(session_file)
          messages << notice("warning", "Saved harness history is unavailable: #{session_file}", "Live controls are disabled until the harness session can be reconciled; no state was deleted.")
        elsif session_file.empty? && agent["harness_session_id"].to_s.empty?
          messages << notice("info", "Worker has no resumable harness history.", "Workspace and delivery-PR actions remain available when their dependencies exist.")
        end

        messages
      rescue SystemCallError => e
        [notice("warning", "Workspace health could not be checked: #{e.message}", "Persisted worker state was left unchanged.")]
      end

      def command_unavailable(kind, command: nil)
        label = kind.to_s.empty? ? "Requested command" : kind.to_s.capitalize
        configured = command.to_s.strip
        detail = configured.empty? ? "Configure a command and retry." : "Configured command was not found: #{configured}"
        notice("warning", "#{label} is unavailable.", "#{detail} Meringue left the worker workspace unchanged.")
      end

      def live_status?(agent)
        %w[queued working idle blocked].include?(agent["status"].to_s)
      end

      def process_missing?(pid)
        numeric_pid = Integer(pid)
        return true unless numeric_pid.positive?

        Process.kill(0, numeric_pid)
        false
      rescue ArgumentError, TypeError, Errno::ESRCH
        true
      rescue Errno::EPERM
        false
      end

      def recovery_detail(agent)
        if !agent["harness_session_file"].to_s.empty? || !agent["harness_session_id"].to_s.empty?
          "Meringue will try non-destructive session recovery during reconciliation."
        else
          "No resumable session reference is tracked; workspace and PR data remain available."
        end
      end

      def notice(level, message, detail)
        { "level" => level, "message" => message, "detail" => detail }
      end
    end
  end
end
