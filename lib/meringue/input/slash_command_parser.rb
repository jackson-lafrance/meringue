# frozen_string_literal: true

require "shellwords"

require_relative "../tui/style"

module Meringue
  module Input
    class SlashCommandParser
      COMMAND_SPECS = [
        ["/help", "Show slash command help."],
        ["/quit", "Quit the interactive TUI."],
        ["/theme <name>", "Set and persist the TUI theme."],
        ["/project add <path> [name]", "Register a project directory."],
        ["/project rename <project_id> \"<name>\"", "Rename a project."],
        ["/issue create <project_id> \"<title>\" [\"description\"]", "Create an issue under a project."],
        ["/issue rename <issue_id> \"<title>\"", "Rename an issue."],
        ["/rename <project_or_issue_id> \"<name>\"", "Quickly rename a project or issue."],
        ["/worker spawn <issue_id> \"<prompt>\"", "Spawn a worker for an issue."],
        ["/prompt <worker_id> \"<message>\"", "Prompt an existing worker session."],
        ["/harness <pi|claude|antigravity>", "Select the active harness backend for future heads and workers."],
        ["/defaults", "Show the model and thinking level for all future Pi sessions."],
        ["/model <provider/model>", "Persist the model for all future Pi sessions; existing sessions are unchanged."],
        ["/thinking <level>", "Persist the thinking level for all future Pi sessions; existing sessions are unchanged."],
        ["/session-settings <agent_id>", "Refresh and show one existing agent's effective Pi model and thinking level."],
        ["/models [harness] [refresh]", "Open the searchable model picker for the harness's own model list; add refresh to re-fetch the catalog instead."],
        ["/goal create <issue_id> \"<success criteria>\" --metric \"<command>\" --target <number> [flags]", "Attach a goal loop to an issue: iterate until the metric hits its target or a budget guard trips."],
        ["/goal status [goal_id]", "Show goal loops, iteration accounting, and stop reasons."],
        ["/goal pause <goal_id>", "Pause a goal loop; the current attempt finishes but nothing new is spawned."],
        ["/goal resume <goal_id>", "Resume a paused goal loop."],
        ["/goal stop <goal_id>", "Stop a goal loop for good, leaving its current attempt session alone."],
        ["/kill <agent_or_issue_id>", "Kill an agent, issue subtree, or project subtree."],
        ["/jump [agent_id]", "Open an agent's focused workspace, or navigate the AgentTree when no id is provided."],
        ["/keybind", "Show all TUI keybindings."],
        ["/config", "Show the active config, supported defaults, conflict policy, and keybindings."],
        ["/tree", "Show the current AgentTree state."],
        ["/state", "Show the raw Meringue state."],
        ["/questions", "List questions and their statuses."],
        ["/answer <question_id> \"<answer>\"", "Answer an open question and let a head route the work it unblocks."],
        ["/dismiss <question_id>", "Dismiss an open question without answering it."],
        ["/prune", "Remove resolved and errored records plus their safely cleanable managed worktrees."],
        ["/recount", "Compact project, issue, worker, and question IDs after records are removed."],
        ["/clear", "Reset persisted Meringue state and clear the visible logs. Dev/debug helper."]
      ].freeze

      ARGUMENT_SUGGESTION_CONTEXTS = [
        { "prefix" => "/harness", "source" => "harness_providers", "append_space" => false },
        { "prefix" => "/models", "source" => "harness_providers", "append_space" => false },
        { "prefix" => "/issue create", "source" => "projects", "append_space" => true },
        { "prefix" => "/project rename", "source" => "projects", "append_space" => true },
        { "prefix" => "/issue rename", "source" => "issues", "append_space" => true },
        { "prefix" => "/rename", "source" => "targets", "append_space" => true },
        { "prefix" => "/worker spawn", "source" => "issues", "append_space" => true },
        { "prefix" => "/prompt", "source" => "workers", "append_space" => true },
        { "prefix" => "/session-settings", "source" => "sessions", "append_space" => false },
        { "prefix" => "/model", "source" => "session_models", "append_space" => false },
        { "prefix" => "/thinking", "source" => "thinking_levels", "append_space" => false },
        { "prefix" => "/kill", "source" => "targets", "append_space" => false },
        { "prefix" => "/theme", "source" => "themes", "append_space" => false },
        { "prefix" => "/jump", "source" => "agents", "append_space" => false },
        { "prefix" => "/answer", "source" => "open_questions", "append_space" => true },
        { "prefix" => "/dismiss", "source" => "open_questions", "append_space" => false },
        { "prefix" => "/goal create", "source" => "issues", "append_space" => true },
        { "prefix" => "/goal status", "source" => "goals", "append_space" => false },
        { "prefix" => "/goal pause", "source" => "goals", "append_space" => false },
        { "prefix" => "/goal resume", "source" => "goals", "append_space" => false },
        { "prefix" => "/goal stop", "source" => "goals", "append_space" => false }
      ].freeze

      GOAL_USAGE_MESSAGE = <<~USAGE.strip
        Usage: /goal create <issue_id> "<success criteria>" --metric "<command>" --target <number> [--comparator gte|lte|gt|lt|eq] [--max-iterations <n>] [--max-workers <n>] [--min-delta <n>] [--no-progress <n>] [--guardrail "<command>"] [--parse last_number|first_number|exit_status|regex|json_path] [--pattern "<regex>"] [--json-path <path>] [--metric-cwd workspace|project_root] [--title "<title>"] [--fresh-attempt] [--paused]
               /goal status [goal_id] | /goal pause <goal_id> | /goal resume <goal_id> | /goal stop <goal_id>
      USAGE
      # Flags that take a following value, so a missing value is reported instead of silently
      # swallowing the next token.
      GOAL_VALUE_FLAGS = {
        "--metric" => "metric_command",
        "--target" => "target",
        "--comparator" => "comparator",
        "--max-iterations" => "max_iterations",
        "--max-workers" => "max_workers",
        "--max-seconds" => "max_wall_clock_seconds",
        "--min-delta" => "min_metric_delta",
        "--no-progress" => "max_consecutive_no_progress",
        "--cooldown" => "min_seconds_between_iterations",
        "--guardrail" => "guardrails",
        "--parse" => "parse",
        "--pattern" => "pattern",
        "--json-path" => "json_path",
        "--metric-cwd" => "metric_cwd",
        "--timeout" => "metric_timeout_seconds",
        "--title" => "title",
        "--judge" => "judge_mode"
      }.freeze
      GOAL_BOOLEAN_FLAGS = {
        "--paused" => ["paused", true],
        "--fresh-attempt" => ["continuity", "fresh_attempt"],
        "--accumulate" => ["continuity", "accumulate"]
      }.freeze

      # `/prune` takes no arguments. These legacy words are still accepted as no-op aliases so
      # existing muscle memory (`/prune resolved`) keeps working and prunes everything eligible.
      PRUNE_COMPATIBILITY_ARGUMENTS = %w[all resolved errored completed merged].freeze
      # Words that make `/models` force a catalog re-fetch rather than reuse the
      # cached snapshot the kernel refreshes in the background.
      MODEL_CATALOG_REFRESH_WORDS = %w[refresh reload force --refresh].freeze
      PRUNE_USAGE_MESSAGE = "Usage: /prune (no arguments; prunes resolved and errored records together)"

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
        return nil unless normalized_query(input)

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
          tokens = argument_text.empty? ? [""] : argument_text.split(/\s+/, -1)
          position = context.fetch("position", 1).to_i
          next unless tokens.length == position

          completion_prefix = ([prefix] + tokens[0...-1]).join(" ")
          return context.merge(
            "query" => tokens.last.to_s,
            "completion_prefix" => completion_prefix,
            "previous_tokens" => tokens[0...-1]
          )
        end

        nil
      end

      def self.records_for_context(context, state)
        state = {} unless state.is_a?(Hash)
        return harness_provider_suggestion_records(context) if context.fetch("source") == "harness_providers"
        return session_value_suggestion_records(context, state) if %w[session_models thinking_levels].include?(context.fetch("source"))

        items = case context.fetch("source")
                when "projects"
                  Array(state["projects"])
                when "issues"
                  Array(state["issues"])
                when "workers"
                  Array(state["agents"]).select { |agent| agent["type"] == "worker" }
                when "sessions"
                  Array(state["agents"]).select do |agent|
                    agent["harness_session_id"] || agent["harness_session_file"] || agent["pid"]
                  end
                when "themes"
                  available_theme_names.map { |theme| { "id" => theme, "theme" => theme } }
                when "targets"
                  Array(state["agents"]) + Array(state["issues"]) + Array(state["projects"])
                when "agents"
                  Array(state["agents"])
                when "open_questions"
                  Array(state["questions"]).select { |question| question["status"] == "open" }
                when "goals"
                  Array(state["goals"])
                else
                  []
                end

        id_suggestion_records(items, context)
      end

      def self.harness_provider_suggestion_records(context)
        query = context.fetch("query", "").to_s.downcase
        listing_models = context.fetch("prefix", "") == "/models"
        Meringue::Harness::Registry.provider_choices.filter_map.with_index do |choice, index|
          provider = choice.fetch("provider")
          label = choice.fetch("label")
          next unless query.empty? || provider.include?(query) || label.downcase.include?(query)

          {
            "usage" => provider,
            "description" => listing_models ? "List the models #{label} reports." : choice.fetch("description"),
            "completion" => "#{context.fetch("prefix")} #{provider}",
            "requires_arguments" => false,
            "append_space" => false,
            "index" => index,
            "kind" => "harness_providers"
          }
        end
      end

      # Model and thinking suggestions come from the harness's own catalog, which
      # the kernel refreshes in the background and persists in state metadata.
      # Completion therefore stays synchronous and never starts a harness process
      # while the user types.
      def self.session_value_suggestion_records(context, state)
        harness = suggestion_harness(context, state)
        catalog = harness_model_catalog(state, harness)
        if context.fetch("source") == "thinking_levels"
          thinking_level_suggestion_records(context, state, catalog, harness)
        else
          model_suggestion_records(context, state, catalog, harness)
        end
      end

      # `/model` and `/thinking` apply to future sessions, so their suggestions
      # follow the active harness.
      def self.suggestion_harness(context, state)
        harness = state.dig("metadata", "active_harness")
        harness = Meringue::Harness::Registry::DEFAULT_PROVIDER if harness.to_s.strip.empty?
        Meringue::Harness::Registry.public_provider_name(harness)
      end

      def self.harness_model_catalog(state, harness)
        Meringue::Harness::ModelCatalog.coerce(
          state.dig("metadata", "harness_model_catalogs", harness),
          harness: harness
        )
      end

      def self.model_suggestion_records(context, state, catalog, harness)
        configured_default = state.dig("metadata", "pi_session_defaults", "model")
        observed = Array(state["agents"]).filter_map { |candidate| candidate.dig("session_settings", "model", "reference") }
        preferred = ([configured_default] + observed).compact.map(&:to_s).reject(&:empty?).uniq
        query = context.fetch("query", "").to_s.downcase
        records = ordered_model_entries(catalog, preferred, harness).filter_map.with_index do |entry, index|
          next unless model_entry_matches?(entry, query)

          {
            "usage" => entry.fetch("reference"),
            "description" => model_suggestion_description(
              entry,
              context,
              configured_default: configured_default,
              catalog: catalog
            ),
            "completion" => "#{context.fetch("completion_prefix")} #{entry.fetch("reference")}",
            "requires_arguments" => false,
            "append_space" => false,
            "index" => index,
            "kind" => "session_models"
          }
        end
        records + model_catalog_note_records(context, catalog, harness, records.length)
      end

      # Ordering: the saved default and models already in use first, then the rest
      # of the harness catalog with providers interleaved.
      def self.ordered_model_entries(catalog, preferred, harness)
        # A last-known (stale) list is still the harness's own answer, so it is
        # offered in full rather than shrinking to the few references Meringue
        # remembers just because the newest refresh failed.
        entries = catalog.usable? ? catalog.models : []
        entries = fallback_model_entries(preferred, harness) if entries.empty?
        by_reference = entries.to_h { |entry| [entry.fetch("reference").downcase, entry] }
        head = preferred.filter_map { |reference| by_reference[reference.to_s.downcase] }
        head + interleaved_by_provider(entries - head)
      end

      # Only a few rows are visible at once, so a provider-grouped list would fill
      # the whole first screen with one provider's models and read like that is all
      # the harness offers. Round-robin across providers instead: the first rows
      # show the real breadth, and typing still narrows to one provider or model.
      def self.interleaved_by_provider(entries)
        grouped = entries
                  .sort_by { |entry| [entry.fetch("provider"), entry.fetch("id")] }
                  .group_by { |entry| entry.fetch("provider") }
        ordered = []
        until grouped.empty?
          grouped.keys.sort.each do |provider|
            models = grouped.fetch(provider)
            ordered << models.shift
            grouped.delete(provider) if models.empty?
          end
        end
        ordered
      end

      # Without a catalog Meringue still completes the references it already knows
      # so an explicit id remains one keystroke away, and labels them unverified.
      def self.fallback_model_entries(preferred, harness)
        references = preferred.dup
        references << Meringue::Harness::Registry::DEFAULT_PI_MODEL if harness == "pi"
        references.uniq.filter_map { |reference| Meringue::Harness::ModelCatalog.normalize_entry("reference" => reference) }
      end

      def self.model_entry_matches?(entry, query)
        return true if query.empty?

        [entry.fetch("reference"), entry.fetch("id"), entry["name"]].compact.any? do |value|
          value.to_s.downcase.include?(query)
        end
      end

      def self.model_suggestion_description(entry, context, configured_default:, catalog:)
        reference = entry.fetch("reference")
        parts = []
        parts << "current default" if !configured_default.to_s.empty? && reference.casecmp?(configured_default.to_s)
        parts << entry["name"] if entry["name"]
        levels = Array(entry["thinking_levels"])
        parts << "thinking: #{levels.join(", ")}" unless levels.empty?
        parts << "#{formatted_context_window(entry["context_window"])} ctx" if entry["context_window"]
        parts << model_suggestion_state_label(catalog)
        parts.compact.join(" · ")
      end

      def self.model_suggestion_state_label(catalog)
        return nil if catalog.available?
        return "last confirmed list" if catalog.stale?

        "catalog unavailable — id not verified"
      end

      def self.formatted_context_window(tokens)
        value = tokens.to_i
        return "#{(value / 1_000_000.0).round(1).to_s.sub(/\.0\z/, "")}M" if value >= 1_000_000
        return "#{(value / 1_000.0).round.to_i}K" if value >= 1_000

        value.to_s
      end

      # One trailing, non-destructive note when the harness could not give us a
      # catalog. Selecting it re-inserts what the user already typed, so it never
      # replaces a valid explicit id.
      def self.model_catalog_note_records(context, catalog, harness, matched_count)
        return [] if catalog.available?
        return [] unless context.fetch("query", "").to_s.empty?

        note = catalog.note.to_s.strip
        note = "Meringue has not fetched #{harness}'s model list yet." if note.empty?
        note = "#{note}." unless note.end_with?(".", "!", "?")
        headline = if catalog.stale?
                     "#{harness} models listed from #{catalog.fetched_at} — latest refresh failed"
                   else
                     "#{harness} model catalog unavailable"
                   end
        [{
          "usage" => headline,
          "description" => "#{note} Run /models refresh to retry; an exact provider/model id still works.",
          "completion" => context.fetch("completion_prefix"),
          "requires_arguments" => false,
          "append_space" => false,
          "index" => matched_count,
          "kind" => "session_models_unavailable"
        }]
      end

      # Thinking levels follow the model in play, so an unsupported level is never
      # offered for a model the harness would reject it for.
      def self.thinking_level_suggestion_records(context, state, catalog, harness)
        reference = thinking_level_model_reference(context, state, harness)
        levels = Array(catalog.thinking_levels_for(reference))
        verified = !levels.empty?
        levels = Meringue::Harness::PiClient::THINKING_LEVELS unless verified
        query = context.fetch("query", "").to_s.downcase
        levels.filter_map.with_index do |level, index|
          next unless query.empty? || level.downcase.include?(query)

          {
            "usage" => level,
            "description" => thinking_level_description(context, reference, verified),
            "completion" => "#{context.fetch("completion_prefix")} #{level}",
            "requires_arguments" => false,
            "append_space" => false,
            "index" => index,
            "kind" => "thinking_levels"
          }
        end
      end

      def self.thinking_level_model_reference(context, state, harness)
        reference = state.dig("metadata", "pi_session_defaults", "model")
        reference = Meringue::Harness::Registry::DEFAULT_PI_MODEL if reference.to_s.strip.empty? && harness == "pi"
        reference.to_s
      end

      def self.thinking_level_description(context, reference, verified)
        scope = "future sessions"
        return "#{scope} · supported by #{reference}" if verified && !reference.to_s.empty?

        "#{scope} · model support not verified yet"
      end

      def self.id_suggestion_records(items, context)
        query = context.fetch("query", "").to_s.downcase
        prefix = context.fetch("completion_prefix", context.fetch("prefix"))
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

      def self.available_theme_names
        if defined?(Meringue::TUI::Style)
          Meringue::TUI::Style.colorschemes
        else
          %w[catppuccin gruvbox kanagawa meringue rose-pine tokyonight]
        end
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
        when "sessions"
          model = item.dig("session_settings", "model", "reference")
          thinking = item.dig("session_settings", "thinking_level")
          [item["harness"] || "session", item["status"], model, thinking].compact.join(" · ")
        when "themes"
          "theme"
        when "targets"
          type = item["type"] || (item.key?("root_path") ? "project" : "issue")
          [type, item["title"] || item["name"], item["status"]].compact.join(" · ")
        when "agents"
          metadata = item.fetch("harness_metadata", {}) || {}
          [item["type"] || "agent", item["status"], metadata["title"] || item["issue_id"]].compact.join(" · ")
        when "open_questions"
          ["question", item["question"].to_s[0, 60]].reject(&:empty?).join(" · ")
        when "goals"
          ["goal", item["status"], item["issue_id"], item["success_criteria"].to_s[0, 40]].compact.reject(&:empty?).join(" · ")
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
        when "quit"
          invalid("/quit is a local TUI command. Run it in the interactive TUI to exit.", usage: "/quit")
        when "theme"
          parse_theme(arguments)
        when "harness"
          parse_harness(arguments)
        when "defaults"
          parse_defaults(arguments)
        when "models"
          parse_models(arguments)
        when "session-settings", "session"
          parse_session_settings(arguments, legacy: command_text == "session")
        when "model"
          parse_model(arguments)
        when "thinking"
          parse_thinking(arguments)
        when "project"
          parse_project(arguments)
        when "issue"
          parse_issue(arguments)
        when "rename"
          parse_rename(arguments)
        when "worker"
          parse_worker(arguments)
        when "prompt"
          parse_prompt(arguments)
        when "kill"
          parse_kill(arguments)
        when "goal", "goals"
          parse_goal(arguments, bare: command_text == "goals")
        when "jump"
          invalid("/jump is a local TUI command. Run it in the interactive TUI to open an agent session.", usage: "/jump [agent_id]")
        when "keybind"
          invalid("/keybind is a local TUI command. Run it in the interactive TUI to show keybindings.", usage: "/keybind")
        when "config"
          invalid("/config is a local TUI command. Run it in the interactive TUI to show the active configuration.", usage: "/config")
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
        when "recount"
          parse_recount(arguments)
        when "clear"
          kernel_command("ClearState")
        else
          invalid("Unknown slash command: /#{command_text}", usage: "/help")
        end
      rescue Shellwords::ParseError => e
        invalid("Could not parse slash command arguments: #{e.message}")
      end

      private

      def parse_theme(arguments)
        tokens = split_arguments(arguments)
        return invalid("Usage: /theme <name>") unless tokens.length == 1

        kernel_command("SetTheme", "theme" => tokens[0])
      end

      def parse_harness(arguments)
        tokens = split_arguments(arguments)
        return invalid("Usage: /harness <pi|claude|antigravity>") unless tokens.length == 1

        kernel_command("SetHarness", "provider" => tokens[0])
      end

      def parse_defaults(arguments)
        return invalid("Usage: /defaults") unless split_arguments(arguments).empty?

        kernel_command("GetSessionDefaults")
      end

      # `/models` opens the local TUI model picker: a searchable list of the
      # models the harness itself reports, where selecting a row is applied as
      # `/model <provider/model>`. Dumping the catalog into the log was unusable
      # once a harness reported a hundred models, so the listing UI moved into
      # the TUI while the kernel command stayed the only source of the catalog.
      #
      # A trailing `refresh` word is still the kernel path: it forces a re-fetch
      # (`GetModelCatalog`) and reports the snapshot's state without opening the
      # picker, which is also what the picker's own refresh key submits and what
      # a head proposes for "what models can I use".
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

      def parse_session_settings(arguments, legacy: false)
        tokens = split_arguments(arguments)
        usage = legacy ? "/session <agent_id> (alias for /session-settings <agent_id>)" : "/session-settings <agent_id>"
        return invalid("Usage: #{usage}") unless tokens.length == 1

        kernel_command("GetSessionSettings", "agent_id" => tokens[0])
      end

      def parse_model(arguments)
        tokens = split_arguments(arguments)
        return invalid("Usage: /model <provider/model>") unless tokens.length == 1

        kernel_command("SetDefaultSessionModel", "model" => tokens[0])
      end

      def parse_thinking(arguments)
        tokens = split_arguments(arguments)
        return invalid("Usage: /thinking <off|minimal|low|medium|high|xhigh|max>") unless tokens.length == 1

        kernel_command("SetDefaultSessionThinkingLevel", "level" => tokens[0])
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
        else
          invalid("Usage: /issue create <project_id> \"<title>\" [\"description\"] | /issue rename <issue_id> \"<title>\"")
        end
      end

      def parse_rename(arguments)
        tokens = split_arguments(arguments)
        return invalid("Usage: /rename <project_or_issue_id> \"<name>\"") unless tokens.length >= 2

        kernel_command("Rename", "target_id" => tokens[0], "name" => tokens[1..].join(" "))
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

      # `/goal` is the user-facing entry point for the goal loop. Every subcommand maps onto
      # one kernel command, so the typed path and a head-proposed command converge.
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

        return invalid(GOAL_USAGE_MESSAGE) unless positional.length == 2

        payload["issue_id"] = positional[0]
        payload["success_criteria"] = positional[1]
        payload["guardrails"] = guardrails unless guardrails.empty?
        kernel_command("CreateGoal", payload)
      end

      # Ids are passed through exactly as typed. The kernel canonicalizes them against state, so
      # `/answer q8` resolves to Q8 while an unknown id keeps the text the user typed in its
      # rejection message. See Meringue::Ids.
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

      # A bare `/prune` performs the full cleanup. A single legacy selector word is accepted as a
      # no-op compatibility alias; anything else is rejected with the short usage message.
      def parse_prune(arguments)
        tokens = split_arguments(arguments)
        return kernel_command("Prune") if tokens.empty?
        return invalid(PRUNE_USAGE_MESSAGE) if tokens.length > 1 || !PRUNE_COMPATIBILITY_ARGUMENTS.include?(tokens[0].to_s.downcase)

        kernel_command("Prune", "selector" => tokens[0].downcase)
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
