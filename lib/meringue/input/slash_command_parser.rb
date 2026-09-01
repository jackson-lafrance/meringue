# frozen_string_literal: true

require "base64"
require "json"
require "shellwords"

require_relative "../tui/style"

module Meringue
  module Input
    class SlashCommandParser
      COMMAND_SPECS = [
        ["/help", "Show slash command help."],
        ["/quit", "Quit the interactive TUI."],
        ["/reload", "Restart Meringue with the current installed source and configuration."],
        ["/update", "Fast-forward the installed Meringue source onto its tracked branch (main, or MERINGUE_BRANCH), install missing dependencies, and reload."],
        ["/theme [name]", "With no arguments, open the theme picker; otherwise set and persist the TUI theme."],
        ["/themes", "Open the interactive theme picker."],
        ["/project add <path> [name]", "Register a project directory."],
        ["/project rename <project_id> \"<name>\"", "Rename a project."],
        ["/project merge <source_project_id> <destination_project_id>", "Merge projects with the same repository identity."],
        ["/project split <source_project_id> <destination_project_id> <issue_id...>", "Extract selected issues into another project."],
        ["/issue create <project_id> \"<title>\" [\"description\"]", "Create an issue under a project."],
        ["/issue rename <issue_id> \"<title>\"", "Rename an issue."],
        ["/issue move <issue_id> <project_id|issue_id|top>", "Move an issue to another project on the same checkout, reparent it under another issue, or promote it to the top level. Its child issues and their workers move with it."],
        ["/issue merge <source_issue_id> <destination_issue_id>", "Merge issue workers and children into a destination issue."],
        ["/issue split <source_issue_id> <destination_issue_id> [worker_id...]", "Extract issue workers into another issue."],
        ["/move <agent_id> <issue_id>", "Move an existing worker to a different issue without restarting its harness session."],
        ["/worker spawn <issue_id> \"<prompt>\"", "Spawn a worker for an issue."],
        ["/worker merge <source_worker_id> <destination_worker_id>", "Merge terminal worker records without combining live sessions."],
        ["/worker split <source_worker_id> <destination_worker_id>", "Extract a worker record while preserving its session and checkout."],
        ["/worker guide \"<additional system prompt>\"", "Persist the additional worker model-selection system prompt when its experiment is enabled."],
        ["/worker pause <agent_id>", "Pause a worker without killing its resumable session."], ["/worker protect <agent_id>", "Protect an agent and its containing issue/project from pruning."],
        ["/worker resume <agent_id>", "Resume a paused worker session."], ["/worker unprotect <agent_id>", "Clear an agent's durable prune protection."],
        ["/worker export <bundle_path> [agent_id...]", "Export current workers for a fresh retry on another computer."],
        ["/worker import <bundle_path> --project <path>", "Import workers as fresh sessions in a destination project."],
        ["/prompt <agent_id> \"<message>\"", "Continue a worker session or take over a still-routing head."],
        ["/retry <head_id>", "Retry a blocked, errored, or killed head with a fresh head."],
        ["/open-session <agent_id>", "TUI local: open an agent's underlying harness session for debugging."],
        ["/harness [head|worker] <pi|claude|codex>", "With no arguments, open the harness picker; otherwise select role-aware harness defaults for future agents; omit the role to update both."],
        ["/model [head|worker] <provider>/<model-id>", "With no arguments, open the model picker; otherwise persist the model for future agent sessions. Omit the role to update both future heads and workers. Existing sessions are unchanged. The model id may itself contain / and :."],
        ["/thinking [head|worker] <level>", "With no arguments, open the Head/Worker thinking picker; otherwise persist a reasoning default for future agent sessions. Omit the role to update both future heads and workers; existing sessions are unchanged."],
        ["/models [harness] [refresh]", "Open the searchable model picker for the harness's own model list; add refresh to re-fetch the catalog instead."],
        ["/goal create [issue_id] \"<prompt>\" --metric \"<command>\" --target <number> [flags]", "Start a goal loop: name an issue, or give only a prompt and Meringue creates the issue for it. It iterates until the metric hits its target or a budget guard trips."],
        ["/goal create [issue_id] \"<prompt>\" --reviewer [--max-iterations <n>]", "Start a reviewer-judged goal loop for work with no number: it iterates until a reviewer approves the work or the iteration budget runs out."],
        ["/goal status [goal_id]", "Show goal loops, iteration accounting, and stop reasons."],
        ["/goal pause <goal_id>", "Pause a goal loop; the current attempt finishes but nothing new is spawned."],
        ["/goal resume <goal_id>", "Resume a paused goal loop."],
        ["/goal stop <goal_id>", "Stop a goal loop for good, leaving its current attempt session alone."],
        ["/kill <agent_or_issue_id>", "Kill an agent, issue subtree, or project subtree."],
        ["/jump [agent_id]", "Open an agent's focused workspace, or navigate the AgentTree when no id is provided."],
        ["/prs", "Open the picker for every tracked pull request that is still open."],
        ["/setup", "Reopen Setup for theme, separate head/worker defaults, and Meringue Xtras."],
        ["/keybind", "Show all TUI keybindings."],
        ["/glossary", "Show what head, worker, issue, project, and harness mean."],
        ["/config", "Open full-screen Settings; /config --text prints read-only diagnostics."],
        ["/github test", "Test read-only GitHub authentication and repository access."],
        ["/tree", "Show the current AgentTree state."],
        ["/state", "Show the raw Meringue state."],
        ["/questions", "Open the picker for existing open questions."],
        ["/answer <question_id> \"<answer>\"", "Answer an open question and let a head route the work it unblocks."],
        ["/dismiss <question_id>", "Dismiss an open question without answering it."],
        ["/prune", "Remove resolved and errored records plus their safely cleanable managed worktrees."],
        ["/recount", "Compact project, issue, worker, and question IDs after records are removed."],
        ["/clear", "Reset persisted Meringue state and clear the visible logs. Dev/debug helper."]
      ].freeze

      # Commands in this table have both accepted singular and plural spellings.
      # Only an argumentless singular command expands to its plural form; any
      # argument keeps the singular command's existing parser contract.
      BARE_SINGULAR_ALIASES = {
        "model" => "models",
        "goal" => "goals"
      }.freeze

      ARGUMENT_SUGGESTION_CONTEXTS = [
        { "prefix" => "/harness head", "source" => "harness_providers", "append_space" => false },
        { "prefix" => "/harness worker", "source" => "harness_providers", "append_space" => false },
        { "prefix" => "/harness", "source" => "harness_providers", "append_space" => false },
        { "prefix" => "/models", "source" => "harness_providers", "append_space" => false },
        { "prefix" => "/issue create", "source" => "projects", "append_space" => true },
        { "prefix" => "/project rename", "source" => "projects", "append_space" => true },
        { "prefix" => "/issue rename", "source" => "issues", "append_space" => true },
        { "prefix" => "/move", "source" => "workers", "append_space" => true },
        { "prefix" => "/worker spawn", "source" => "issues", "append_space" => true },
        { "prefix" => "/worker pause", "source" => "workers", "append_space" => false },
        { "prefix" => "/worker resume", "source" => "workers", "append_space" => false },
        { "prefix" => "/worker export", "source" => "workers", "append_space" => true },
        { "prefix" => "/prompt", "source" => "prompt_targets", "append_space" => true },
        { "prefix" => "/retry", "source" => "retry_heads", "append_space" => false },
        { "prefix" => "/open-session", "source" => "agents", "append_space" => false },
        { "prefix" => "/model head", "source" => "session_models", "append_space" => false, "model_role" => "head" },
        { "prefix" => "/model worker", "source" => "session_models", "append_space" => false, "model_role" => "worker" },
        { "prefix" => "/model", "source" => "session_models", "append_space" => false },
        { "prefix" => "/thinking head", "source" => "thinking_levels", "append_space" => false, "thinking_role" => "head" },
        { "prefix" => "/thinking worker", "source" => "thinking_levels", "append_space" => false, "thinking_role" => "worker" },
        { "prefix" => "/thinking", "source" => "thinking_levels", "append_space" => false },
        { "prefix" => "/kill", "source" => "targets", "append_space" => false },
        { "prefix" => "/theme", "source" => "themes", "append_space" => false },
        { "prefix" => "/jump", "source" => "agents", "append_space" => false },
        { "prefix" => "/answer", "source" => "open_questions", "append_space" => true },
        { "prefix" => "/dismiss", "source" => "open_questions", "append_space" => false },
        { "prefix" => "/goal create", "source" => "goal_create_targets", "append_space" => true },
        { "prefix" => "/goal status", "source" => "goals", "append_space" => false },
        { "prefix" => "/goal pause", "source" => "goals", "append_space" => false },
        { "prefix" => "/goal resume", "source" => "goals", "append_space" => false },
        { "prefix" => "/goal stop", "source" => "goals", "append_space" => false }
      ].freeze

      GOAL_USAGE_MESSAGE = <<~USAGE.strip
        Usage: /goal create "<prompt>" --metric "<command>" --target <number> [--project <project_id>] [flags]   (Meringue creates the issue)
               /goal create <issue_id> "<success criteria>" --metric "<command>" --target <number> [flags]      (attach to an existing issue)
               /goal create [issue_id] "<prompt>" --reviewer [flags]                                            (no metric: a reviewer judges each iteration)
               flags: [--comparator gte|lte|gt|lt|eq] [--max-iterations <n>] [--max-workers <n>] [--min-delta <n>] [--no-progress <n>] [--guardrail "<command>"] [--parse last_number|first_number|exit_status|regex|json_path] [--pattern "<regex>"] [--json-path <path>] [--metric-cwd workspace|project_root] [--title "<title>"] [--fresh-attempt] [--paused]
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
        "--project" => "project_id",
        "--timeout" => "metric_timeout_seconds",
        "--title" => "title",
        "--judge" => "judge_mode"
      }.freeze
      GOAL_BOOLEAN_FLAGS = {
        "--paused" => ["paused", true],
        # The friendly spelling of `--judge reviewer`: iterate until a reviewer session
        # approves the work instead of until a metric command hits a number.
        "--reviewer" => ["judge_mode", "reviewer"],
        "--fresh-attempt" => ["continuity", "fresh_attempt"],
        "--accumulate" => ["continuity", "accumulate"]
      }.freeze

      # Words that make `/models` force a catalog re-fetch rather than reuse the
      # cached snapshot the kernel refreshes in the background.
      MODEL_CATALOG_REFRESH_WORDS = %w[refresh reload force --refresh].freeze
      PRUNE_USAGE_MESSAGE = "Usage: /prune (no arguments; prunes resolved and errored records together)"
      # Bare `/setup` opens the local first-run flow in the TUI. The two outcome
      # words are the kernel spelling: they record the completion marker in the
      # config file through `CompleteOnboarding`, so it is validated, journaled,
      # and logged like any other kernel command instead of a silent UI write.
      SETUP_OUTCOMES = {
        "complete" => "completed",
        "completed" => "completed",
        "done" => "completed",
        "skip" => "skipped",
        "skipped" => "skipped"
      }.freeze
      SETUP_USAGE_MESSAGE = "Usage: /setup [complete|skip]"
      # The bare `/rename <id> "<name>"` shortcut was removed: renaming now always names the
      # record kind, so the command that runs is obvious from what was typed. The word is still
      # matched here (instead of falling through to "Unknown slash command") so muscle memory
      # gets pointed at the namespaced spelling rather than a generic error.
      RENAME_USAGE_MESSAGE = "Usage: /project rename <project_id> \"<name>\" | /issue rename <issue_id> \"<title>\""
      RENAME_REMOVED_MESSAGE = "/rename was removed. #{RENAME_USAGE_MESSAGE}"

      def self.expand_bare_singular_alias(command_text, arguments)
        command = command_text.to_s.downcase
        return command unless arguments.to_s.empty?

        BARE_SINGULAR_ALIASES.fetch(command, command)
      end

      def self.command_suggestions(input = nil, limit: nil, state: nil)
        command_suggestion_records(input, limit: limit, state: state).map do |record|
          [record.fetch("usage"), record.fetch("description")]
        end
      end

      def self.command_suggestion_records(input = nil, limit: 3, state: nil)
        inline_records = inline_suggestion_records(input, state)
        return inline_records.first(limit || inline_records.length) if inline_records

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

      # Inline model and thinking completions are deliberately separate from slash
      # commands. They let a user express a worker preference in ordinary routing
      # text without changing the worker defaults or bypassing head selection.
      def self.inline_suggestion_active?(input)
        input.to_s.match?(/(?:\A|\s)([@#])(?:\S*)\z/)
      end

      def self.inline_suggestion_records(input, state)
        raw = input.to_s
        match = raw.match(/(?:\A|\s)([@#])(\S*)\z/)
        return nil unless match

        trigger = match[1]
        query = match[2].to_s
        prefix = raw[0...match.begin(2)]
        context = {
          "source" => trigger == "@" ? "session_models" : "thinking_levels",
          "model_role" => "worker",
          "thinking_role" => "worker",
          "query" => query,
          "completion_prefix" => prefix
        }
        records = session_value_suggestion_records(context, state)
        records.map do |record|
          value = record.fetch("usage")
          completion = record.fetch("kind", nil) == "session_models_unavailable" ? prefix : "#{prefix}#{value}"
          record.merge(
            "completion" => completion,
            "inline_trigger" => trigger,
            "append_space" => false
          )
        end
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
        return goal_create_suggestion_records(context, state) if context.fetch("source") == "goal_create_targets"
        return session_value_suggestion_records(context, state) if %w[session_models thinking_levels].include?(context.fetch("source"))

        items = case context.fetch("source")
                when "projects"
                  Array(state["projects"])
                when "issues"
                  Array(state["issues"])
                when "workers"
                  Array(state["agents"]).select { |agent| agent["type"] == "worker" }
                when "prompt_targets"
                  Array(state["agents"]).select do |agent|
                    next true if agent["type"] == "worker"
                    next false unless agent["type"] == "head"

                    %w[queued working idle].include?(agent["status"].to_s) && !Meringue::State::Models.head_result_applied?(agent)
                  end
                when "retry_heads"
                  Array(state["agents"]).select { |agent| Meringue::State::Models.head_retry_target?(agent) }
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

      # `/goal create` takes an issue id *or* a quoted prompt, so its completion offers the issues
      # and says out loud that the id is optional. The note row is inert: selecting it re-inserts
      # exactly what was already typed, so it can never overwrite a real id.
      def self.goal_create_suggestion_records(context, state)
        issues = id_suggestion_records(Array(state["issues"]), context.merge("source" => "issues"))
        return issues unless context.fetch("query", "").to_s.empty?

        note = {
          "usage" => "\"<prompt>\"",
          "description" => "no issue needed · quote a prompt and Meringue creates the issue (--project <project_id> picks the project)",
          "completion" => context.fetch("completion_prefix", context.fetch("prefix")),
          "requires_arguments" => false,
          "append_space" => false,
          "index" => 0,
          "kind" => "goal_create_prompt"
        }
        [note] + issues.map.with_index { |record, index| record.merge("index" => index + 1) }
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
        configured_default = current_default_model(state, harness, context["model_role"])
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
        references << Meringue::Harness::Registry::DEFAULT_MODEL if Meringue::Harness::Registry.session_defaults_supported_for?(harness)
        references.uniq.filter_map { |reference| Meringue::Harness::ModelCatalog.normalize_entry("reference" => reference) }
      end

      def self.model_entry_matches?(entry, query)
        return true if query.empty?

        normalized_query = model_search_text(query)
        [entry.fetch("reference"), entry.fetch("id"), entry["name"]].compact.any? do |value|
          model_search_text(value).include?(normalized_query)
        end
      end

      # Keep model references faithful in the UI while making autocomplete
      # forgiving about punctuation users commonly omit while typing. In
      # particular, `gpt5` matches both `gpt-5.6-luna` and `gpt-5.5`.
      def self.model_search_text(value)
        value.to_s.downcase.delete("-")
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

      # `/thinking` offers every level the kernel accepts, and lets the catalog
      # label them instead of removing them.
      #
      # Filtering the list by the catalog silently hid levels a user could really
      # set: kernel validation is deliberately catalog-independent (the same rule
      # `/model` follows), and a harness may adjust a level a model does not
      # advertise rather than reject it. A provider extension that omits `max`
      # from its model metadata can therefore make `/thinking max` succeed while
      # `max` is missing from `/thinking`'s own list, hiding the saved default.
      def self.thinking_level_suggestion_records(context, state, catalog, harness)
        reference = thinking_level_model_reference(state, harness, context["thinking_role"])
        supported = normalized_thinking_levels(catalog.thinking_levels_for(reference))
        current = current_default_thinking_level(state, harness, context["thinking_role"])
        query = context.fetch("query", "").to_s.strip.downcase
        matching_thinking_levels(query, current).map.with_index do |level, index|
          {
            "usage" => level,
            "description" => thinking_level_description(level, reference, supported, current, harness),
            "completion" => "#{context.fetch("completion_prefix")} #{level}",
            "requires_arguments" => false,
            "append_space" => false,
            "index" => index,
            "kind" => "thinking_levels",
            "current" => level == current
          }
        end
      end

      # Every reasoning level in Meringue's harness-neutral vocabulary.
      # Completion and kernel validation must agree, so both read one contract.
      def self.thinking_levels
        Meringue::Harness::ModelCatalog::THINKING_LEVELS
      end

      def self.thinking_usage_message
        "Usage: /thinking [head|worker] <#{thinking_levels.join("|")}>"
      end

      def self.model_usage_message
        "Usage: /model [head|worker] <provider>/<model-id> (one token; the model id may itself contain / and :, " \
          "as in #{Meringue::Harness::ModelReference::MULTI_SEGMENT_EXAMPLE})"
      end

      # With nothing typed the saved default leads the list: only three suggestion
      # rows are visible at once, so a level at the far end of the ladder (`max`)
      # would otherwise need scrolling to see, which is what made it look absent.
      # Once the user types, prefix matches lead instead, so completing "hi"
      # cannot resolve to a current default of "xhigh".
      def self.matching_thinking_levels(query, current)
        return ordered_thinking_levels(current) if query.empty?

        prefixed, contained = thinking_levels.select { |level| level.include?(query) }
                                             .partition { |level| level.start_with?(query) }
        prefixed + contained
      end

      def self.ordered_thinking_levels(current)
        levels = thinking_levels.dup
        return levels unless levels.include?(current)

        [current] + (levels - [current])
      end

      def self.current_default_thinking_level(state, harness, role = nil)
        defaults = state.dig("metadata", "agent_session_defaults") || {}
        level = if %w[head worker].include?(role.to_s)
                  role_level = defaults.dig("roles", role.to_s, "thinking_level").to_s.strip
                  role_level.empty? ? defaults["thinking_level"] : role_level
                else
                  defaults["thinking_level"]
                end
        level = level.to_s.strip.downcase
        level = Meringue::Harness::Registry::DEFAULT_THINKING_LEVEL if level.empty? && role.nil? && Meringue::Harness::Registry.session_defaults_supported_for?(harness)
        level
      end

      # Mirrors `current_default_thinking_level`: a role payload reads that
      # role's effective model (falling back to the shared summary), while the
      # bare form reads the shared summary that is nil when roles differ.
      def self.current_default_model(state, harness, role = nil)
        defaults = state.dig("metadata", "agent_session_defaults") || {}
        model = if %w[head worker].include?(role.to_s)
                  role_model = defaults.dig("roles", role.to_s, "model").to_s.strip
                  role_model.empty? ? defaults["model"] : role_model
                else
                  defaults["model"]
                end
        model = model.to_s.strip
        model = Meringue::Harness::Registry::DEFAULT_MODEL if model.empty? && role.nil? && Meringue::Harness::Registry.session_defaults_supported_for?(harness)
        model
      end

      def self.normalized_thinking_levels(levels)
        Array(levels).map { |level| level.to_s.strip.downcase }.reject(&:empty?)
      end

      def self.thinking_level_model_reference(state, harness, role = nil)
        defaults = state.dig("metadata", "agent_session_defaults") || {}
        reference = if %w[head worker].include?(role.to_s)
                      role_reference = defaults.dig("roles", role.to_s, "model").to_s.strip
                      role_reference.empty? ? defaults["model"] : role_reference
                    else
                      defaults["model"]
                    end
        reference = reference.to_s.strip
        reference = Meringue::Harness::Registry::DEFAULT_MODEL if reference.empty? && Meringue::Harness::Registry.session_defaults_supported_for?(harness)
        reference
      end

      def self.thinking_level_description(level, reference, supported, current, harness)
        scope = level == current ? "current default" : "future sessions"
        "#{scope} · #{thinking_level_support_label(level, reference, supported, harness)}"
      end

      # Says what the catalog knows without treating an advertised list as a
      # permission boundary. A harness-specific adjustment policy is resolved in
      # the integration registry rather than assumed by this generic parser.
      def self.thinking_level_support_label(level, reference, supported, harness)
        return "model support not verified yet" if supported.empty? || reference.to_s.empty?
        return "supported by #{reference}" if supported.include?(level)

        label = Meringue::Harness::Registry.provider_label(harness)
        adjusted = Meringue::Harness::Registry.adjusted_thinking_level(harness, level, supported)
        return "not listed for #{reference} · #{label} adjusts it to #{adjusted}" if adjusted

        "not listed for #{reference} · verify support with #{label}"
      end

      # Id completion for `/kill`, `/prompt`, `/jump`, and friends is ranked shallowest-first:
      # among the ids that match what was typed, the record that owns a subtree is offered before
      # the records inside it. Typing `i10` lists P3-I10 above P3-I10-W1, and typing `p3` lists P3,
      # then P3-I10, then P3-I10-W1 — start short, then go long.
      #
      # A typed fragment almost always names the thing the user is thinking about ("kill that
      # issue"), and its workers are one arrow key away; the previous order came from whatever
      # sequence the state sections happened to be concatenated in, which put an issue's own
      # workers above it. Which records match is unchanged, only their order.
      #
      # With nothing typed each source keeps its own order (`/prompt` lists worker sessions before
      # the failed heads it can retry, `/kill` lists agents before issues before projects). That is
      # a relevance decision the source made, not an accident of id shape, so ranking only kicks in
      # once there is a query to rank against.
      def self.id_suggestion_records(items, context)
        query = context.fetch("query", "").to_s.downcase
        prefix = context.fetch("completion_prefix", context.fetch("prefix"))
        source = context.fetch("source")
        matches = Array(items).filter_map.with_index do |item, index|
          id = item["id"].to_s
          next if id.empty?
          next unless query.empty? || id.downcase.include?(query)

          { "item" => item, "id" => id, "index" => index }
        end
        ranked_id_suggestions(matches, query).map.with_index do |match, index|
          id = match.fetch("id")
          {
            "usage" => id,
            "description" => description_for_suggestion(match.fetch("item"), source),
            "completion" => "#{prefix} #{id}",
            "requires_arguments" => context.fetch("append_space"),
            "append_space" => context.fetch("append_space"),
            "index" => index,
            "kind" => source
          }
        end
      end

      def self.ranked_id_suggestions(matches, query)
        return matches if query.empty?

        matches.sort_by { |match| id_suggestion_sort_key(match.fetch("id"), match.fetch("index"), query) }
      end

      # Sort key, most significant part first:
      #
      #   1. an exact match on what was typed (`/kill p3-i10` keeps P3-I10 on top)
      #   2. record ids before anything else, so a non-id list (themes) is never reshuffled
      #   3. id depth: P3 before P3-I10 before P3-I10-W1, and H<n>/Q<n>/G<n> count as depth 0
      #   4. id namespace, so one depth is not interleaved (H1, H2, P1, P2 rather than H1, P1, H2)
      #   5. numeric order within the namespace: P3-I2 before P3-I10 before P10-I1
      #
      # Ids of the same depth and namespace share a shape, so numeric order is also shortest-first.
      # The trailing id/index pair only breaks ties, and keeps non-record entries in source order.
      def self.id_suggestion_sort_key(id, index, query)
        exact = id.downcase == query ? 0 : 1
        return [exact, 1, 0, "", [], "", index] unless Meringue::Ids.record_id?(id)

        segments = id.upcase.scan(/[A-Z]+|\d+/)
        namespace = segments.grep(/[A-Z]/).join
        numbers = segments.grep(/\d/).map(&:to_i)
        [exact, 0, numbers.length - 1, namespace, numbers, id.downcase, index]
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
        when "workers", "prompt_targets"
          [item["type"] == "head" ? "head" : "worker", item["status"], item["issue_id"]].compact.join(" · ")
        when "retry_heads"
          ["head", item["status"], "retry"].compact.join(" · ")
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
        command_text = self.class.expand_bare_singular_alias(command_text, arguments)

        case command_text
        when "help"
          kernel_command("Help")
        when "quit"
          invalid("/quit is a local TUI command. Run it in the interactive TUI to exit.", usage: "/quit")
        when "reload"
          invalid("/reload is a local TUI command. Run it in the interactive TUI to restart Meringue.", usage: "/reload")
        when "update"
          invalid("/update is a local TUI command. Run it in the interactive TUI to update and restart Meringue.", usage: "/update")
        when "theme"
          parse_theme(arguments)
        when "themes"
          parse_themes(arguments)
        when "harness"
          parse_harness(arguments)
        when "models"
          parse_models(arguments)
        when "model"
          parse_model(arguments)
        when "thinking"
          parse_thinking(arguments)
        when "project"
          parse_project(arguments)
        when "issue"
          parse_issue(arguments)
        when "rename"
          invalid(RENAME_REMOVED_MESSAGE, usage: RENAME_USAGE_MESSAGE)
        when "move", "reparent"
          parse_move(arguments)
        when "worker"
          parse_worker(arguments)
        when "prompt"
          parse_prompt(arguments)
        when "retry"
          parse_retry(arguments)
        when "open-session", "open_session"
          invalid("/open-session is a local TUI command. Run it in the interactive TUI to open an agent session for debugging.", usage: "/open-session <agent_id>")
        when "kill"
          parse_kill(arguments)
        when "goal", "goals"
          parse_goal(arguments, bare: command_text == "goals")
        when "setup"
          parse_setup(arguments)
        when "jump"
          invalid("/jump is a local TUI command. Run it in the interactive TUI to open an agent session.", usage: "/jump [agent_id]")
        when "prs"
          invalid("/prs is a local TUI command. Run it in the interactive TUI to open the pull-request picker.", usage: "/prs")
        when "keybind"
          invalid("/keybind is a local TUI command. Run it in the interactive TUI to show keybindings.", usage: "/keybind")
        when "glossary", "terms"
          invalid("/glossary is a local TUI command. Run it in the interactive TUI to show the vocabulary.", usage: "/glossary")
        when "config"
          parse_config(arguments)
        when "github"
          parse_github(arguments)
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
      # `Shellwords.split` raises `ArgumentError` for an unbalanced quote. This used to
      # rescue `Shellwords::ParseError`, a constant Ruby does not define, so evaluating the
      # rescue clause raised `NameError` instead and `/answer Q1 "unterminated` escaped the
      # parser entirely rather than becoming a usage message.
      rescue ArgumentError => e
        invalid("Could not parse slash command arguments: #{e.message}", usage: "/help")
      end

      private






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

      # One token, handed to the kernel exactly as typed. The provider is
      # everything before the first slash and the model id keeps the rest, so a
      # real reference such as
      # `fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast` passes
      # through unchanged; `Meringue::Harness::ModelReference` owns the grammar.
      # A leading `head` or `worker` token scopes the default to that role, so
      # `/model head <provider>/<model-id>` updates only future heads. A shared
      # `/model <provider>/<model-id>` updates both roles and clears role
      # overrides, mirroring `/thinking`.





      # One destination argument covers the three things "move this issue" can
      # mean, because the id shape already says which: a project id moves the
      # issue to that board, an issue id reparents it beneath that issue, and the
      # literal `top` promotes it out of whatever issue currently owns it.




      # `/move <agent_id> <issue_id>` reparents an existing worker onto a different issue. The
      # kernel keeps the harness session, worktree, and branch intact; only the AgentTree
      # assignment (and the worker's composite id) changes. `/reparent` is the same command.


      # `/goal` is the user-facing entry point for the goal loop. Every subcommand maps onto
      # one kernel command, so the typed path and a head-proposed command converge.


      # Two forms share one verb, so the first positional token decides between them and an
      # id-shaped token is *never* reinterpreted as prose:
      #
      #   /goal create P1-I7 "<success criteria>"   attach a goal to an existing issue
      #   /goal create "<prompt>"                   mint the issue from the prompt, then attach
      #
      # A mistyped or incomplete id therefore fails loudly here (or, if it is issue-shaped but
      # names nothing, in the kernel) instead of silently becoming a new issue's title.









    end
  end
end
