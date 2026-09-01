# frozen_string_literal: true

module Meringue
  module Input
    class SlashCommandParser
    private
      def parse_config(arguments)
        tokens = split_arguments(arguments)
        if tokens.empty? || tokens == ["--text"]
          return invalid("/config is a local TUI command. Run it in the interactive TUI to edit the active configuration.", usage: "/config")
        end
        return invalid("Usage: /config") unless tokens.length == 2 && tokens.first == "save"
        return invalid("Configuration save payload is too large.") if tokens.last.bytesize > 1_000_000

        decoded = Base64.urlsafe_decode64(tokens.last)
        payload = JSON.parse(decoded)
        unless payload.is_a?(Hash) && payload["changes"].is_a?(Hash) && payload["base_fingerprint"].is_a?(String)
          return invalid("Configuration save payload is invalid.")
        end

        command_payload = {
          "base_fingerprint" => payload.fetch("base_fingerprint"),
          "changes" => payload.fetch("changes")
        }
        if payload.key?("onboarding_outcome")
          outcome = payload.fetch("onboarding_outcome").to_s
          return invalid("Configuration save payload has an invalid setup outcome.") unless Config::ONBOARDING_OUTCOMES.include?(outcome)

          command_payload["onboarding_outcome"] = outcome
        end
        kernel_command("SaveConfiguration", command_payload)
      rescue ArgumentError, JSON::ParserError
        invalid("Configuration save payload is invalid.")
      end

      def parse_github(arguments)
        tokens = split_arguments(arguments)
        return kernel_command("TestGitHubAccess") if tokens == ["test"]
        return kernel_command("TestGitHubAccess", "draft_github_support" => true) if tokens == ["test", "--draft-support"]
        invalid("Usage: /github test")
      end

      def parse_theme(arguments)
        tokens = split_arguments(arguments)
        return invalid(
          "Usage: /theme [name]. Without a name, this local TUI command opens the theme picker in the interactive TUI.",
          usage: "/theme [name]"
        ) if tokens.empty?
        return invalid("Usage: /theme [name]") unless tokens.length == 1

        kernel_command("SetTheme", "theme" => tokens[0])
      end

      def parse_themes(arguments)
        tokens = split_arguments(arguments)
        return invalid(
          "Usage: /themes. This local TUI command opens the theme picker in the interactive TUI.",
          usage: "/themes"
        ) if tokens.empty?

        invalid("Usage: /themes")
      end

      def parse_harness(arguments)
        tokens = split_arguments(arguments)
        return kernel_command("SetHarness", "provider" => tokens[0]) if tokens.length == 1
        if tokens.length == 2 && %w[head worker].include?(tokens[0].to_s.downcase)
          return kernel_command("SetHarness", "role" => tokens[0].downcase, "provider" => tokens[1])
        end

        invalid("Usage: /harness [head|worker] <pi|claude|codex>")
      end

      def parse_models(arguments)
        tokens = split_arguments(arguments)
        refresh_words, harness_words = tokens.partition { |token| MODEL_CATALOG_REFRESH_WORDS.include?(token.to_s.downcase) }
        return invalid("Usage: /models [harness] [refresh]") if harness_words.length > 1 || refresh_words.length > 1

        if refresh_words.empty?
          return invalid(
            "/models is a local TUI command. Run it in the interactive TUI to open the model picker, or /models refresh to re-fetch the catalog.",
            usage: "/models [harness] [refresh]"
          )
        end

        payload = { "refresh" => true }
        payload["harness"] = harness_words[0] if harness_words[0]
        kernel_command("GetModelCatalog", payload)
      end

      def parse_model(arguments)
        tokens = split_arguments(arguments)
        if tokens.length == 2 && %w[head worker].include?(tokens[0].to_s.downcase)
          return kernel_command("SetDefaultSessionModel", "role" => tokens[0].downcase, "model" => tokens[1])
        end
        unless tokens.length == 1
          return invalid(self.class.model_usage_message)
        end

        kernel_command("SetDefaultSessionModel", "model" => tokens[0])
      end

      def parse_thinking(arguments)
        tokens = split_arguments(arguments)
        if tokens.length == 1
          return kernel_command("SetDefaultSessionThinkingLevel", "level" => tokens[0])
        end
        unless tokens.length == 2 && %w[head worker].include?(tokens[0].to_s.downcase)
          return invalid(self.class.thinking_usage_message)
        end

        kernel_command(
          "SetDefaultSessionThinkingLevel",
          "role" => tokens[0].downcase,
          "level" => tokens[1]
        )
      end

      def parse_setup(arguments)
        tokens = split_arguments(arguments)
        if tokens.empty?
          return invalid(
            "/setup is a local TUI command. Run it in the interactive TUI to review theme, separate head/worker defaults, and Meringue Xtras.",
            usage: "/setup"
          )
        end
        return invalid(SETUP_USAGE_MESSAGE) unless tokens.length == 1

        outcome = SETUP_OUTCOMES[tokens[0].to_s.strip.downcase]
        return invalid(SETUP_USAGE_MESSAGE) unless outcome

        kernel_command("CompleteOnboarding", "outcome" => outcome)
      end

      def parse_project(arguments)
        tokens = split_arguments(arguments)
        case tokens.first
        when "add"
          kernel_command(
            "AddProject",
            "path" => tokens[1],
            "name" => tokens[2..]&.join(" ")
          )
        when "rename"
          return invalid("Usage: /project rename <project_id> \"<name>\"") unless tokens.length >= 3

          kernel_command("ModifyProject", "project_id" => tokens[1], "name" => tokens[2..].join(" "))
        when "merge", "split"
          return invalid("Usage: /project #{tokens.first} <source_project_id> <destination_project_id> [issue_id...]") unless tokens.length >= 3
          type = tokens.first == "merge" ? "MergeProject" : "SplitProject"
          payload = { "source_id" => tokens[1], "destination_id" => tokens[2] }
          payload["issue_ids"] = tokens[3..] if type == "SplitProject"
          kernel_command(type, payload)
        else
          invalid("Usage: /project add <path> [name] | /project rename <project_id> \"<name>\"")
        end
      end

      def parse_issue(arguments)
        tokens = split_arguments(arguments)
        case tokens.first
        when "create"
          kernel_command(
            "CreateIssue",
            "project_id" => tokens[1],
            "title" => tokens[2],
            "description" => tokens[3..]&.join(" ")
          )
        when "rename"
          return invalid("Usage: /issue rename <issue_id> \"<title>\"") unless tokens.length >= 3

          kernel_command("ModifyIssue", "issue_id" => tokens[1], "title" => tokens[2..].join(" "))
        when "move"
          parse_issue_move(tokens)
        when "merge", "split"
          return invalid("Usage: /issue #{tokens.first} <source_issue_id> <destination_issue_id> [worker_id...]") unless tokens.length >= 3
          type = tokens.first == "merge" ? "MergeIssue" : "SplitIssue"
          payload = { "source_id" => tokens[1], "destination_id" => tokens[2] }
          payload["worker_ids"] = tokens[3..] if type == "SplitIssue"
          kernel_command(type, payload)
        else
          invalid("Usage: /issue create <project_id> \"<title>\" [\"description\"] | /issue rename <issue_id> \"<title>\" | /issue move <issue_id> <project_id|issue_id|top> | /issue merge <source_issue_id> <destination_issue_id> | /issue split <source_issue_id> <destination_issue_id> [worker_id...]")
        end
      end

      def parse_issue_move(tokens)
        return invalid("Usage: /issue move <issue_id> <project_id|issue_id|top>") unless tokens.length == 3

        issue_id = tokens[1]
        destination = tokens[2].to_s.strip
        return kernel_command("MoveIssue", "issue_id" => issue_id, "parent_issue_id" => "") if %w[top none root].include?(destination.downcase)
        return kernel_command("MoveIssue", "issue_id" => issue_id, "parent_issue_id" => destination) if destination.match?(/\A[Pp]\d+-[Ii]\d+\z/)
        return kernel_command("MoveIssue", "issue_id" => issue_id, "target_project_id" => destination) if destination.match?(/\A[Pp]\d+\z/)

        invalid("Usage: /issue move <issue_id> <project_id|issue_id|top>")
      end

      def parse_worker(arguments)
        tokens = split_arguments(arguments)
        case tokens.first.to_s.downcase
        when "spawn"
          kernel_command(
            "SpawnWorker",
            "issue_id" => tokens[1],
            "prompt" => tokens[2..]&.join(" ")
          )
        when "guide"
          return invalid("Usage: /worker guide \"<additional system prompt>\"") if tokens.length < 2

          kernel_command("SetWorkerSelectionGuidance", "prompt" => tokens[1..].join(" "))
        when "pause", "resume"
          return invalid("Usage: /worker #{tokens.first.downcase} <agent_id>") unless tokens.length == 2

          kernel_command(tokens.first.to_s.downcase == "pause" ? "PauseWorker" : "ResumeWorker", "agent_id" => tokens[1])
        when "protect", "unprotect"
          return invalid("Usage: /worker #{tokens.first.downcase} <agent_id>") unless tokens.length == 2

          kernel_command("SetAgentPruneProtection", "agent_id" => tokens[1], "protected" => tokens.first.to_s.downcase == "protect")
        when "merge", "split"
          return invalid("Usage: /worker #{tokens.first} <source_worker_id> <destination_worker_id>") unless tokens.length == 3
          kernel_command(tokens.first == "merge" ? "MergeWorker" : "SplitWorker", "source_id" => tokens[1], "destination_id" => tokens[2])
        when "export"
          return invalid("Usage: /worker export <bundle_path> [agent_id...]") if tokens.length < 2

          kernel_command("ExportWorkers", "path" => tokens[1], "worker_ids" => tokens[2..] || [])
        when "import"
          return invalid("Usage: /worker import <bundle_path> --project <path>") if tokens.length < 4

          project_index = tokens.index { |token| token.to_s == "--project" }
          return invalid("Usage: /worker import <bundle_path> --project <path>") unless project_index == 2 && tokens[3]
          return invalid("Usage: /worker import <bundle_path> --project <path>") unless tokens.length == 4

          kernel_command("ImportWorkers", "path" => tokens[1], "project_path" => tokens[3])
        else
          invalid("Usage: /worker spawn <issue_id> \"<prompt>\" | /worker guide \"<additional system prompt>\" | /worker pause <agent_id> | /worker resume <agent_id> | /worker protect <agent_id> | /worker unprotect <agent_id> | /worker export <bundle_path> [agent_id...] | /worker import <bundle_path> --project <path>")
        end
      end

      def parse_prompt(arguments)
        tokens = split_arguments(arguments)
        kernel_command(
          "PromptAgent",
          "agent_id" => tokens[0],
          "prompt" => tokens[1..]&.join(" ")
        )
      end

      def parse_retry(arguments)
        tokens = split_arguments(arguments)
        return invalid("Usage: /retry <head_id>") unless tokens.length == 1

        kernel_command("RetryHead", "head_id" => tokens[0])
      end

      def parse_move(arguments)
        tokens = split_arguments(arguments)
        return invalid("Usage: /move <agent_id> <issue_id>") unless tokens.length == 2

        kernel_command("MoveWorker", "agent_id" => tokens[0], "target_issue_id" => tokens[1])
      end

      def parse_kill(arguments)
        tokens = split_arguments(arguments)
        kernel_command("Kill", "target_id" => tokens[0])
      end

      def parse_goal(arguments, bare: false)
        tokens = split_arguments(arguments)
        return kernel_command("ListGoals") if bare && tokens.empty?

        subcommand = tokens.first.to_s.downcase
        rest = tokens[1..] || []
        case subcommand
        when "", "status", "list", "show"
          return invalid(GOAL_USAGE_MESSAGE) if rest.length > 1

          kernel_command("ListGoals", "goal_id" => rest[0])
        when "create", "add", "new"
          parse_goal_create(rest)
        when "pause"
          return invalid("Usage: /goal pause <goal_id>") unless rest.length == 1

          kernel_command("ModifyGoal", "goal_id" => rest[0], "paused" => true)
        when "resume", "unpause"
          return invalid("Usage: /goal resume <goal_id>") unless rest.length == 1

          kernel_command("ModifyGoal", "goal_id" => rest[0], "paused" => false)
        when "stop", "cancel"
          return invalid("Usage: /goal stop <goal_id>") unless rest.length == 1

          kernel_command("StopGoal", "goal_id" => rest[0])
        else
          invalid(GOAL_USAGE_MESSAGE)
        end
      end

      def parse_goal_create(tokens)
        positional = []
        payload = {}
        guardrails = []
        index = 0
        while index < tokens.length
          token = tokens[index].to_s
          if (boolean = GOAL_BOOLEAN_FLAGS[token.downcase])
            payload[boolean[0]] = boolean[1]
            index += 1
          elsif (key = GOAL_VALUE_FLAGS[token.downcase])
            value = tokens[index + 1]
            return invalid("#{token} needs a value. #{GOAL_USAGE_MESSAGE}") if value.nil? || value.to_s.start_with?("--")

            if key == "guardrails"
              guardrails << value
            else
              payload[key] = value
            end
            index += 2
          elsif token.start_with?("--")
            return invalid("Unknown /goal create flag #{token}. #{GOAL_USAGE_MESSAGE}")
          else
            positional << token
            index += 1
          end
        end

        target = goal_create_target(positional)
        return target if target.is_a?(Meringue::Kernel::Command)

        payload.merge!(target)
        payload["guardrails"] = guardrails unless guardrails.empty?
        kernel_command("CreateGoal", payload)
      end

      def goal_create_target(positional)
        case positional.length
        when 1
          token = positional[0].to_s
          return invalid(goal_create_lone_id_message(token)) if Meringue::Ids.record_id?(token)

          { "prompt" => token }
        when 2
          first = positional[0].to_s
          return invalid(goal_create_first_token_message(first)) unless Meringue::Ids::ISSUE_PATTERN.match?(first)

          { "issue_id" => first, "success_criteria" => positional[1] }
        when 0
          invalid("/goal create needs a prompt, or an issue id and its success criteria. #{GOAL_USAGE_MESSAGE}")
        else
          invalid(
            "/goal create takes one quoted prompt, or an issue id plus quoted success criteria; " \
            "got #{positional.length} arguments. Quote the whole prompt as a single argument. #{GOAL_USAGE_MESSAGE}"
          )
        end
      end

      def goal_create_lone_id_message(token)
        "#{token} looks like a record id, so /goal create still needs the success criteria for it: " \
          "/goal create #{token} \"<success criteria>\" ... Quote your text instead if you meant it as a new prompt. #{GOAL_USAGE_MESSAGE}"
      end

      def goal_create_first_token_message(first)
        if Meringue::Ids::PROJECT_PATTERN.match?(first)
          "#{first} is a project id, not an issue id. Use /goal create \"<prompt>\" --project #{first} to let Meringue create the issue. #{GOAL_USAGE_MESSAGE}"
        elsif Meringue::Ids.record_id?(first)
          "#{first} is not an issue id. Name an issue as P<n>-I<n>, or quote a prompt to have Meringue create the issue. #{GOAL_USAGE_MESSAGE}"
        else
          "/goal create takes one quoted prompt, or an issue id plus quoted success criteria. " \
            "Quote the whole prompt as a single argument. #{GOAL_USAGE_MESSAGE}"
        end
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

      # `/prune` takes no arguments. The selector it used to accept is gone, along with
      # the list of spellings that were tolerated for compatibility - which this still
      # named, so any argument at all raised NameError instead of printing the usage.
      def parse_prune(arguments)
        return kernel_command("Prune") if split_arguments(arguments).empty?

        invalid(PRUNE_USAGE_MESSAGE)
      end

      def parse_recount(arguments)
        return invalid("Usage: /recount") unless split_arguments(arguments).empty?

        kernel_command("Recount")
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
