# frozen_string_literal: true

require "shellwords"

module Meringue
  module Input
    class SlashCommandParser
      COMMAND_SPECS = [
        ["/help", "Show slash command help."],
        ["/project add <path> [name]", "Register a project directory."],
        ["/issue create <project_id> \"<title>\" [\"description\"]", "Create an issue under a project."],
        ["/worker spawn <issue_id> \"<prompt>\"", "Spawn a worker for an issue."],
        ["/prompt <agent_id> \"<message>\"", "Prompt an existing agent session."],
        ["/kill <agent_or_issue_id>", "Kill an agent, issue subtree, or project subtree."],
        ["/tree", "Show the current AgentTree state."],
        ["/state", "Show the raw Meringue state."],
        ["/questions", "List questions and their statuses."],
        ["/answer <question_id> \"<answer>\"", "Answer a pending question."],
        ["/clear", "Reset persisted Meringue state. Dev/debug helper."]
      ].freeze

      def self.command_suggestions
        COMMAND_SPECS
      end

      def parse(input)
        stripped = input.to_s.strip
        return nil unless stripped.start_with?("/")

        command_text, arguments = stripped.delete_prefix("/").split(/\s+/, 2)
        command_text = command_text.to_s.downcase
        arguments = arguments.to_s

        case command_text
        when "help"
          kernel_command("Help")
        when "project"
          parse_project(arguments)
        when "issue"
          parse_issue(arguments)
        when "worker"
          parse_worker(arguments)
        when "prompt"
          parse_prompt(arguments)
        when "kill"
          parse_kill(arguments)
        when "tree"
          kernel_command("ListAll", "view" => "tree")
        when "state"
          kernel_command("GetState")
        when "questions"
          kernel_command("ListQuestions")
        when "answer"
          parse_answer(arguments)
        when "clear"
          kernel_command("ClearState")
        else
          invalid("Unknown slash command: /#{command_text}", usage: "/help")
        end
      rescue Shellwords::ParseError => e
        invalid("Could not parse slash command arguments: #{e.message}")
      end

      private

      def parse_project(arguments)
        tokens = split_arguments(arguments)
        return invalid("Usage: /project add <path> [name]") unless tokens.first == "add"

        kernel_command(
          "AddProject",
          "path" => tokens[1],
          "name" => tokens[2..]&.join(" ")
        )
      end

      def parse_issue(arguments)
        tokens = split_arguments(arguments)
        return invalid("Usage: /issue create <project_id> \"<title>\" [\"description\"]") unless tokens.first == "create"

        kernel_command(
          "CreateIssue",
          "project_id" => tokens[1],
          "title" => tokens[2],
          "description" => tokens[3..]&.join(" ")
        )
      end

      def parse_worker(arguments)
        tokens = split_arguments(arguments)
        return invalid("Usage: /worker spawn <issue_id> \"<prompt>\"") unless tokens.first == "spawn"

        kernel_command(
          "SpawnWorker",
          "issue_id" => tokens[1],
          "prompt" => tokens[2..]&.join(" ")
        )
      end

      def parse_prompt(arguments)
        tokens = split_arguments(arguments)
        kernel_command(
          "PromptAgent",
          "agent_id" => tokens[0],
          "prompt" => tokens[1..]&.join(" ")
        )
      end

      def parse_kill(arguments)
        tokens = split_arguments(arguments)
        kernel_command("Kill", "target_id" => tokens[0])
      end

      def parse_answer(arguments)
        tokens = split_arguments(arguments)
        kernel_command(
          "AnswerQuestion",
          "question_id" => tokens[0],
          "answer" => tokens[1..]&.join(" ")
        )
      end

      def split_arguments(arguments)
        Shellwords.split(arguments.to_s)
      end

      def kernel_command(type, payload = {})
        Meringue::Kernel::Command.new(type: type, payload: payload.compact)
      end

      def invalid(message, usage: nil)
        kernel_command(
          "InvalidSlashCommand",
          {
            "message" => message,
            "usage" => usage,
            "commands" => COMMAND_SPECS.map { |usage_text, description| { "usage" => usage_text, "description" => description } }
          }.compact
        )
      end
    end
  end
end
