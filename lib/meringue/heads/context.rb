# frozen_string_literal: true

module Meringue
  module Heads
    class Context
      DEFAULT_KERNEL_COMMANDS_PATH = Meringue.root_path("docs", "head_agent_kernel_commands.md")
      ACTIVE_STATUSES = %w[queued working idle].freeze

      attr_reader :head_id, :user_message, :snapshot, :question_id,
                  :kernel_commands_path, :cwd

      def initialize(head_id:, user_message:, snapshot:, question_id: nil,
                     kernel_commands_path: DEFAULT_KERNEL_COMMANDS_PATH, cwd: Dir.pwd)
        @head_id = head_id
        @user_message = user_message
        @snapshot = snapshot
        @question_id = question_id
        @kernel_commands_path = kernel_commands_path
        @cwd = File.expand_path(cwd)
      end

      def to_h
        {
          "head_id" => head_id,
          "user_message" => user_message,
          "question_id" => question_id,
          "cwd" => cwd,
          "kernel_state" => snapshot,
          "agent_tree" => agent_tree,
          "active_heads" => active_heads,
          "active_workers" => active_workers,
          "unresolved_questions" => unresolved_questions,
          "kernel_command_reference" => kernel_command_reference
        }
      end

      def system_prompt
        <<~PROMPT
          You are a stateless Meringue head agent.
          Read the user message, inspect the supplied Meringue snapshot, and return a HeadResult JSON object only.
          Do not mutate files or state directly. Propose kernel commands using the reference below.

          #{kernel_command_reference}
        PROMPT
      end

      def reference_metadata
        {
          "path" => kernel_commands_path,
          "bytes" => kernel_command_reference.bytesize,
          "lines" => kernel_command_reference.lines.count
        }
      end

      private

      def kernel_command_reference
        @kernel_command_reference ||= File.read(kernel_commands_path)
      rescue Errno::ENOENT
        raise ArgumentError, "Head kernel command reference not found: #{kernel_commands_path}"
      end

      def agent_tree
        {
          "projects" => snapshot.fetch("projects", []),
          "issues" => snapshot.fetch("issues", []),
          "agents" => snapshot.fetch("agents", []),
          "questions" => snapshot.fetch("questions", []),
          "status_counts" => status_counts
        }
      end

      def active_heads
        snapshot.fetch("agents", []).select do |agent|
          agent.fetch("type", nil) == "head" && ACTIVE_STATUSES.include?(agent.fetch("status", nil))
        end
      end

      def active_workers
        snapshot.fetch("agents", []).select do |agent|
          agent.fetch("type", nil) == "worker" && ACTIVE_STATUSES.include?(agent.fetch("status", nil))
        end
      end

      def unresolved_questions
        snapshot.fetch("questions", []).select do |question|
          question.fetch("status", nil) == "open"
        end
      end

      def status_counts
        snapshot.fetch("agents", []).each_with_object(Hash.new(0)) do |agent, counts|
          counts[agent.fetch("status", "unknown")] += 1
        end
      end
    end
  end
end
