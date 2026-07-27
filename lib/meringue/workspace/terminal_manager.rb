# frozen_string_literal: true

module Meringue
  module Workspace
    # Keeps one shell session per visible worker and provides a single cleanup
    # point for TUI shutdown. Sessions are intentionally independent from the
    # worker harness process even when both use the same worktree.
    class TerminalManager
      def self.from_config(config, env: ENV)
        section = config.respond_to?(:section) ? config.section("workspace") : {}
        section = {} unless section.is_a?(Hash)
        command = section["shell_command"]
        max_buffer_bytes = section.fetch("terminal_buffer_bytes", TerminalSession::DEFAULT_BUFFER_BYTES)
        new(session_factory: lambda {
          TerminalSession.new(command: command, env: env, max_buffer_bytes: max_buffer_bytes)
        })
      end

      def initialize(session_factory: -> { TerminalSession.new })
        @session_factory = session_factory
        @sessions = {}
        @mutex = Mutex.new
      end

      def session_for(agent)
        key = agent_key(agent)
        return nil unless key

        @mutex.synchronize { @sessions[key] ||= @session_factory.call }
      end

      def start(agent, rows: TerminalSession::DEFAULT_ROWS, columns: TerminalSession::DEFAULT_COLUMNS)
        session = session_for(agent)
        return { "status" => "rejected", "message" => "Select a worker before opening a terminal." } unless session

        workspace_path = workspace_path_for(agent)
        session.start(workspace_path: workspace_path, rows: rows, columns: columns)
      end

      def fetch(agent_or_id)
        key = agent_key(agent_or_id)
        key && @mutex.synchronize { @sessions[key] }
      end

      def close(agent_or_id)
        key = agent_key(agent_or_id)
        session = key && @mutex.synchronize { @sessions.delete(key) }
        return { "status" => "closed", "message" => "No workspace terminal was running." } unless session

        session.close
      end

      def close_all
        sessions = @mutex.synchronize do
          current = @sessions.values
          @sessions = {}
          current
        end
        failures = sessions.filter_map do |session|
          result = session.close
          result if result.fetch("status", nil) == "failed"
        end
        if failures.empty?
          { "status" => "closed", "message" => "Stopped #{sessions.length} workspace terminal#{sessions.length == 1 ? "" : "s"}." }
        else
          { "status" => "failed", "message" => failures.map { |failure| failure.fetch("message", "Terminal cleanup failed.") }.join(" ") }
        end
      end

      def statuses
        @mutex.synchronize { @sessions.transform_values(&:status) }
      end

      private

      def agent_key(agent_or_id)
        value = if agent_or_id.is_a?(Hash)
                  return nil unless agent_or_id.fetch("type", "worker").to_s == "worker"

                  agent_or_id.fetch("id", nil)
                else
                  agent_or_id
                end
        key = value.to_s.strip
        key.empty? ? nil : key
      end

      def workspace_path_for(agent)
        return nil unless agent.is_a?(Hash)

        metadata = agent.fetch("harness_metadata", {}) || {}
        agent["workspace_path"] || metadata["cwd"]
      end
    end
  end
end
