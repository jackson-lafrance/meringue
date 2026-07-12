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
        ["/prompt <worker_id> \"<message>\"", "Prompt an existing worker session."],
        ["/harness <pi|claude|antigravity>", "Select the active harness backend for future heads and workers."],
        ["/kill <agent_or_issue_id>", "Kill an agent, issue subtree, or project subtree."],
        ["/jump [agent_id]", "Open an agent harness session in Alacritty, or navigate the AgentTree when no id is provided."],
        ["/jumpr [agent_id]", "Open an agent pull request, or navigate agents with attached PRs when no id is provided."],
        ["/keybind", "Show all TUI keybindings."],
        ["/tree", "Show the current AgentTree state."],
        ["/state", "Show the raw Meringue state."],
        ["/questions", "List questions and their statuses."],
        ["/answer <question_id> \"<answer>\"", "Answer a pending question."],
        ["/dismiss <question_id>", "Dismiss an open question without answering it."],
        ["/prune <merged|errored>", "Remove merged PR issue bundles or errored records from active state."],
        ["/clear", "Reset persisted Meringue state. Dev/debug helper."]
      ].freeze

      ARGUMENT_SUGGESTION_CONTEXTS = [
        { "prefix" => "/harness", "source" => "harness_providers", "append_space" => false },
        { "prefix" => "/issue create", "source" => "projects", "append_space" => true },
        { "prefix" => "/worker spawn", "source" => "issues", "append_space" => true },
        { "prefix" => "/prompt", "source" => "workers", "append_space" => true },
        { "prefix" => "/kill", "source" => "targets", "append_space" => false },
        { "prefix" => "/jump", "source" => "agents", "append_space" => false },
        { "prefix" => "/jumpr", "source" => "pr_agents", "append_space" => false },
        { "prefix" => "/answer", "source" => "open_questions", "append_space" => true },
        { "prefix" => "/dismiss", "source" => "open_questions", "append_space" => false }
      ].freeze

      def self.command_suggestions(input = nil, limit: nil, state: nil)
        command_suggestion_records(input, limit: limit, state: state).map do |record|
          [record.fetch("usage"), record.fetch("description")]
        end
      end

      def self.command_suggestion_records(input = nil, limit: 3, state: nil)
        argument_records = argument_suggestion_records(input, state)
        return argument_records.first(limit || argument_records.length) if argument_records

        query = normalized_query(input)
        records = COMMAND_SPECS.each_with_index.map do |(usage, description), index|
          completion = completion_prefix_for(usage)
          requires_arguments = completion != usage
          {
            "usage" => usage,
            "description" => description,
            "completion" => completion,
            "requires_arguments" => requires_arguments,
            "append_space" => requires_arguments,
            "index" => index,
            "kind" => "command"
          }
        end
        records = records.select { |record| suggestion_matches?(record, query) } if query
        records.first(limit || records.length)
      end

      def self.normalized_query(input)
        return nil if input.nil?

        stripped = input.to_s.strip.downcase.gsub(/\s+/, " ")
        return nil unless stripped.start_with?("/")

        stripped
      end

      def self.suggestion_matches?(record, query)
        return true if query == "/"

        usage = record.fetch("usage").downcase
        return false if usage.start_with?("/prune") && query.length < "/pr".length

        completion = record.fetch("completion").downcase
        usage.start_with?(query) || completion.start_with?(query) || usage.include?(query)
      end

      def self.completion_prefix_for(usage)
        usage.to_s.split.take_while { |token| token !~ /\A[<\[]/ }.join(" ")
      end

      def self.argument_suggestion_records(input, state)
        return nil unless state && normalized_query(input)

        context = argument_suggestion_context(input)
        return nil unless context

        records_for_context(context, state)
      end

      def self.argument_suggestion_context(input)
        raw = input.to_s.lstrip
        raw_downcase = raw.downcase

        ARGUMENT_SUGGESTION_CONTEXTS.each do |context|
          prefix = context.fetch("prefix")
          next unless raw_downcase.start_with?("#{prefix} ")

          argument_text = raw[prefix.length + 1..] || ""
          return nil if argument_text.match?(/\s/)

          return context.merge("query" => argument_text)
        end

        nil
      end

      def self.records_for_context(context, state)
        return harness_provider_suggestion_records(context) if context.fetch("source") == "harness_providers"

        items = case context.fetch("source")
                when "projects"
                  Array(state["projects"])
                when "issues"
                  Array(state["issues"])
                when "workers"
                  Array(state["agents"]).select { |agent| agent["type"] == "worker" }
                when "targets"
                  Array(state["agents"]) + Array(state["issues"]) + Array(state["projects"])
                when "agents"
                  Array(state["agents"])
                when "pr_agents"
                  pr_agents(state)
                when "open_questions"
                  Array(state["questions"]).select { |question| question["status"] == "open" }
                else
                  []
                end

        id_suggestion_records(items, context)
      end

      def self.harness_provider_suggestion_records(context)
        query = context.fetch("query", "").to_s.downcase
        Meringue::Harness::Registry.provider_choices.filter_map.with_index do |choice, index|
          provider = choice.fetch("provider")
          label = choice.fetch("label")
          next unless query.empty? || provider.include?(query) || label.downcase.include?(query)

          {
            "usage" => provider,
            "description" => choice.fetch("description"),
            "completion" => "#{context.fetch("prefix")} #{provider}",
            "requires_arguments" => false,
            "append_space" => false,
            "index" => index,
            "kind" => "harness_providers"
          }
        end
      end

      def self.id_suggestion_records(items, context)
        query = context.fetch("query", "").to_s.downcase
        prefix = context.fetch("prefix")
        source = context.fetch("source")
        Array(items).filter_map.with_index do |item, index|
          id = item["id"].to_s
          next if id.empty?
          next unless query.empty? || id.downcase.start_with?(query) || id.downcase.include?(query)

          {
            "usage" => id,
            "description" => description_for_suggestion(item, source),
            "completion" => "#{prefix} #{id}",
            "requires_arguments" => context.fetch("append_space"),
            "append_space" => context.fetch("append_space"),
            "index" => index,
            "kind" => source
          }
        end
      end

      def self.pr_agents(state)
        Array(state["agents"]).filter_map do |agent|
          pr_url = first_pr_url_for_agent(agent)
          pr_url ? agent.merge("_pr_url" => pr_url) : nil
        end
      end

      def self.first_pr_url_for_agent(agent)
        agent["_pr_url"] || pr_urls_from_record(agent).find { |url| pull_request_url?(url) }
      end

      def self.pr_urls_from_record(record)
        metadata = record.fetch("harness_metadata", {}) || {}
        delivery_pull_requests = [
          record["delivery_pull_request"],
          metadata["delivery_pull_request"],
          *Array(record["delivery_pull_requests"]),
          *Array(metadata["delivery_pull_requests"])
        ].compact
        delivery_pull_requests.map { |pull_request| pull_request.is_a?(Hash) ? pull_request["url"] : pull_request.to_s }
      end

      def self.pull_request_url?(url)
        url.to_s.match?(%r{\Ahttps?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+(?:[/?#].*)?\z})
      end

      def self.description_for_suggestion(item, source)
        case source
        when "harness_providers"
          ["harness", item["label"]].compact.join(" · ")
        when "projects"
          ["project", item["name"], item["status"]].compact.join(" · ")
        when "issues"
          ["issue", item["title"], item["status"]].compact.join(" · ")
        when "workers"
          ["worker", item["status"], item["issue_id"]].compact.join(" · ")
        when "targets"
          type = item["type"] || (item.key?("root_path") ? "project" : "issue")
          [type, item["title"] || item["name"], item["status"]].compact.join(" · ")
        when "agents"
          metadata = item.fetch("harness_metadata", {}) || {}
          [item["type"] || "agent", item["status"], metadata["title"] || item["issue_id"]].compact.join(" · ")
        when "pr_agents"
          metadata = item.fetch("harness_metadata", {}) || {}
          ["agent PR", item["type"], metadata["title"] || item["issue_id"], first_pr_url_for_agent(item)].compact.join(" · ")
        when "open_questions"
          ["question", item["question"].to_s[0, 60]].reject(&:empty?).join(" · ")
        else
          ""
        end
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
        when "harness"
          parse_harness(arguments)
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
        when "jump"
          invalid("/jump is a local TUI command. Run it in the interactive TUI to open an agent session.", usage: "/jump [agent_id]")
        when "jumpr"
          invalid("/jumpr is a local TUI command. Run it in the interactive TUI to open an agent pull request.", usage: "/jumpr [agent_id]")
        when "keybind"
          invalid("/keybind is a local TUI command. Run it in the interactive TUI to show keybindings.", usage: "/keybind")
        when "tree"
          kernel_command("ListAll", "view" => "tree")
        when "state"
          kernel_command("GetState")
        when "questions"
          kernel_command("ListQuestions")
        when "answer"
          parse_answer(arguments)
        when "dismiss"
          parse_dismiss(arguments)
        when "prune"
          parse_prune(arguments)
        when "clear"
          kernel_command("ClearState")
        else
          invalid("Unknown slash command: /#{command_text}", usage: "/help")
        end
      rescue Shellwords::ParseError => e
        invalid("Could not parse slash command arguments: #{e.message}")
      end

      private

      def parse_harness(arguments)
        tokens = split_arguments(arguments)
        return invalid("Usage: /harness <pi|claude|antigravity>") unless tokens.length == 1

        kernel_command("SetHarness", "provider" => tokens[0])
      end

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

      def parse_dismiss(arguments)
        tokens = split_arguments(arguments)
        return invalid("Usage: /dismiss <question_id>") unless tokens.length == 1

        kernel_command("DismissQuestion", "question_id" => tokens[0])
      end

      def parse_prune(arguments)
        tokens = split_arguments(arguments)
        selector = tokens[0]
        return invalid("Usage: /prune <merged|errored>") unless %w[merged errored].include?(selector.to_s.downcase)

        kernel_command("Prune", "selector" => selector.to_s.downcase)
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
