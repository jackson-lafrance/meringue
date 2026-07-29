# frozen_string_literal: true

module Meringue
  module TUI
    # Slash commands available inside a focused worker workspace.
    #
    # They are deliberately scoped to the selected worker: the dashboard keeps
    # owning project/issue orchestration, and everything here maps to an action
    # the workspace already exposes through its leader key or to a turn-level
    # session operation the kernel owns. Anything not starting with `/` is still
    # a direct follow-up prompt for the worker.
    module WorkspaceCommands
      # Mirrors the persisted transcript filters rather than restating them.
      FILTERS = State::Models::AGENT_WORKSPACE_FILTERS

      # usage, description, action
      COMMAND_SPECS = [
        ["/help", "List focused workspace commands.", "workspace_help"],
        ["/terminal", "Switch between the terminal and agent view.", "workspace_switch_view"],
        ["/filter [#{FILTERS.join("|")}]", "Set the transcript filter, or cycle it when no value is given.", "workspace_filter"],
        ["/open-session", "Open this worker's underlying agent session externally.", "workspace_open_agent_session"],
        ["/editor", "Open the worker worktree in the configured editor.", "workspace_open_editor"],
        ["/pr", "Open the verified delivery pull request.", "workspace_open_pull_request"],
        ["/cwd", "Show the worker's resolved worktree directory.", "workspace_cwd"],
        ["/cancel", "Cancel the worker's current turn without ending its session.", "workspace_cancel_turn"],
        ["/quit", "Return to the AgentTree, keeping the worker and its terminal alive.", "workspace_close"]
      ].freeze

      # Aliases stay harness-agnostic: no alias may name a specific backend.
      ALIASES = {
        "?" => "help",
        "commands" => "help",
        "view" => "terminal",
        "shell" => "terminal",
        "session" => "open-session",
        "agent" => "open-session",
        "edit" => "editor",
        "pull-request" => "pr",
        "abort" => "cancel",
        "stop" => "cancel",
        "back" => "quit",
        "close" => "quit",
        "tree" => "quit",
        "pwd" => "cwd",
        "path" => "cwd"
      }.freeze

      def self.slash_prompt?(input)
        input.to_s.strip.start_with?("/")
      end

      def self.command_suggestion_records(input = nil, limit: nil, state: nil)
        records = filter_argument_records(input) || command_records(input)
        limit ? records.first(limit) : records
      end

      # Returns { "action" => ..., "arguments" => [...] } or { "error" => ... }.
      def self.resolve(input)
        text = input.to_s.strip
        return { "error" => "Workspace commands start with /." } unless slash_prompt?(text)

        name, argument_text = text.delete_prefix("/").split(/\s+/, 2)
        name = ALIASES.fetch(name.to_s.downcase, name.to_s.downcase)
        spec = COMMAND_SPECS.find { |usage, _description, _action| command_name(usage) == name }
        return { "error" => "Unknown workspace command /#{name}. Type / to list workspace commands." } unless spec

        arguments = argument_text.to_s.split(/\s+/)
        action = spec.fetch(2)
        return validate_filter(arguments) if action == "workspace_filter"
        unless arguments.empty?
          return { "error" => "/#{name} does not take arguments." }
        end

        { "action" => action, "arguments" => [] }
      end

      def self.help_lines
        COMMAND_SPECS.map { |usage, description, _action| "#{usage} — #{description}" }
      end

      def self.command_name(usage)
        usage.to_s.delete_prefix("/").split(/\s+/).first.to_s.downcase
      end

      def self.validate_filter(arguments)
        return { "action" => "workspace_filter", "arguments" => [] } if arguments.empty?
        return { "error" => "Usage: /filter [#{FILTERS.join("|")}]" } unless arguments.length == 1

        value = arguments.first.to_s.downcase
        return { "error" => "Unknown transcript filter #{value.inspect}. Use one of: #{FILTERS.join(", ")}." } unless FILTERS.include?(value)

        { "action" => "workspace_filter", "arguments" => [value] }
      end
      private_class_method :validate_filter

      def self.command_records(input)
        query = normalized_query(input)
        records = COMMAND_SPECS.each_with_index.map do |(usage, description, action), index|
          completion = usage.split(/\s+/).first
          takes_arguments = completion != usage
          {
            "usage" => usage,
            "description" => description,
            "action" => action,
            "completion" => completion,
            "requires_arguments" => takes_arguments,
            "append_space" => takes_arguments,
            "index" => index,
            "kind" => "workspace_command"
          }
        end
        return records unless query

        records.select { |record| matches?(record, query) }
      end
      private_class_method :command_records

      def self.filter_argument_records(input)
        raw = input.to_s.lstrip
        return nil unless raw.downcase.start_with?("/filter ")

        query = raw[("/filter ".length)..].to_s
        return nil if query.match?(/\s/)

        FILTERS.filter_map.with_index do |value, index|
          next unless query.empty? || value.start_with?(query.downcase)

          {
            "usage" => value,
            "description" => value == "all" ? "Show every transcript category." : "Show only #{value} entries.",
            "action" => "workspace_filter",
            "completion" => "/filter #{value}",
            "requires_arguments" => false,
            "append_space" => false,
            "index" => index,
            "kind" => "workspace_filter"
          }
        end
      end
      private_class_method :filter_argument_records

      def self.normalized_query(input)
        return nil if input.nil?

        stripped = input.to_s.strip.downcase.gsub(/\s+/, " ")
        stripped.start_with?("/") ? stripped : nil
      end
      private_class_method :normalized_query

      def self.matches?(record, query)
        return true if query == "/"

        usage = record.fetch("usage").downcase
        completion = record.fetch("completion").downcase
        bare = query.delete_prefix("/")
        usage.start_with?(query) || completion.start_with?(query) ||
          ALIASES.any? { |alias_name, target| alias_name.start_with?(bare) && "/#{target}" == completion }
      end
      private_class_method :matches?
    end
  end
end
